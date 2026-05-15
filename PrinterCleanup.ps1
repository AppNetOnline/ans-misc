#Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Removes stale Windows printer objects, PnP devices, and related registry artifacts that match caller-supplied patterns.

.DESCRIPTION
    Performs stale printer cleanup in the correct service stop/start order.

    Cleanup order:
        1. Verify required device, RPC, and print services are running.
        2. Remove matched printers with Remove-Printer and PrintUIEntry.
        3. Remove matched or phantom Win32_PnPEntity printer devices with pnputil.
        4. Remove matched or phantom Get-PnpDevice printer entries.
        5. Stop the Print Spooler before registry and filesystem cleanup.
        6. Remove matched HKLM PRINTENUM registry keys.
        7. Remove matched machine-level Print\Connections registry keys.
        8. Remove matched machine-level Print\Printers registry keys.
        9. Mount local user hives, remove matched Printers\Connections keys, and unmount.
       10. Clear Client Side Rendering Print Provider cache.
       11. Clear Device Metadata filesystem caches.
       12. Remove matched Chrome print preview cached destinations.
       13. Restart services.

.PARAMETER Patterns
    Strings to match against printer names, device names, captions, port names, driver names,
    instance IDs, and registry key/property values.

.PARAMETER LogDirectory
    Directory where the cleanup log should be written.

.EXAMPLE
    .\Remove-StaleServerPrinters.ps1 -Patterns 'OLD-PRINT01', '\\OLD-PRINT01';

.EXAMPLE
    .\Remove-StaleServerPrinters.ps1 -Patterns 'OLD-PRINT01', 'OLD-PRINT01.contoso.com', 'Front Desk';

.NOTES
    Updated: 2026-05-15
#>

[CmdletBinding(SupportsShouldProcess = $True)]
Param(
    [Parameter(
        Mandatory = $True
    )]
    [ValidateNotNullOrEmpty()]
    [String[]]
    $Patterns,

    [Parameter(
        Mandatory = $False
    )]
    [ValidateNotNullOrEmpty()]
    [String]
    $LogDirectory = "$env:ProgramData\PrinterCleanup"
)

Set-StrictMode -Version Latest;
$ErrorActionPreference = 'Stop';

#region Initialize Logging

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null;

$LogPath = Join-Path -Path $LogDirectory -ChildPath 'Remove-StaleServerPrinters.log';

#endregion Initialize Logging

#region Functions

Function Write-CleanupLog {
    [CmdletBinding()]
    Param(
        [Parameter(
            Mandatory = $True
        )]
        [ValidateNotNullOrEmpty()]
        [String]
        $Message,

        [Parameter(
            Mandatory = $False
        )]
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')]
        [String]
        $Level = 'INFO'
    )

    $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message";

    Add-Content -Path $LogPath -Value $Entry -ErrorAction SilentlyContinue;

    Switch ($Level) {
        'INFO' {
            Write-Host -ForegroundColor DarkGray "[i] $Message";
        }

        'SUCCESS' {
            Write-Host -ForegroundColor Green "[+] $Message";
        }

        'WARN' {
            Write-Host -ForegroundColor Yellow "[!] $Message";
        }

        'ERROR' {
            Write-Host -ForegroundColor Red "[X] $Message";
        }
    }
}

Function Test-MatchesPattern {
    [CmdletBinding()]
    Param(
        [Parameter(
            Mandatory = $False
        )]
        [AllowNull()]
        [String]
        $Text,

        [Parameter(
            Mandatory = $True
        )]
        [ValidateNotNullOrEmpty()]
        [String[]]
        $PatternList
    )

    If ([String]::IsNullOrWhiteSpace($Text)) {
        Return $False;
    };

    ForEach ($Pattern in $PatternList) {
        If ($Text -like "*$Pattern*") {
            Return $True;
        };
    };

    Return $False;
}

Function Get-RegistryItemSearchText {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $True)]
        [Object]$RegistryItem
    )

    $TextParts = @(
        $RegistryItem.Name,
        $RegistryItem.PSChildName
    );

    Try {
        $Properties = Get-ItemProperty -Path $RegistryItem.PSPath -ErrorAction Stop;

        ForEach ($Property in $Properties.PSObject.Properties) {
            If ($Property.Name -like 'PS*') {
                Continue;
            }

            If ($Property.Value -is [Array]) {
                $ValueText = $Property.Value -join ' ';
            }
            Else {
                $ValueText = $Property.Value;
            }

            $TextParts += "$($Property.Name) $ValueText";
        }
    }
    Catch {
        # Some protected registry keys cannot be read. Key-name matching still applies.
    }

    Return ($TextParts -join ' ');
};

Function Test-RegistryTreeMatchesPattern {
    [CmdletBinding()]
    Param(
        [Parameter(
            Mandatory = $True
        )]
        [ValidateNotNullOrEmpty()]
        [String]
        $Path,

        [Parameter(
            Mandatory = $True
        )]
        [ValidateNotNullOrEmpty()]
        [String[]]
        $PatternList
    )

    If (-not (Test-Path -Path $Path)) {
        Return $False;
    };

    $Items = @();

    Try {
        $Items += Get-Item -Path $Path -ErrorAction Stop;
        $Items += Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue;
    }
    Catch {
        Return $False;
    }

    ForEach ($Item in $Items) {
        $Text = Get-RegistryItemSearchText -RegistryItem $Item;

        If (Test-MatchesPattern -Text $Text -PatternList $PatternList) {
            Return $True;
        };
    };

    Return $False;
};

Function Remove-RegistryKeyIfPresent {
    [CmdletBinding()]
    Param(
        [Parameter(
            Mandatory = $True
        )]
        [ValidateNotNullOrEmpty()]
        [String]
        $Path,

        [Parameter(
            Mandatory = $True
        )]
        [ValidateNotNullOrEmpty()]
        [String]
        $DisplayName
    )

    If (-not (Test-Path -Path $Path)) {
        Write-CleanupLog -Level INFO -Message "Already removed: $DisplayName";
        Return;
    };

    Try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop;

        Write-CleanupLog -Level SUCCESS -Message "Removed: $DisplayName";

        Return;
    }
    Catch {
        If (-not (Test-Path -Path $Path)) {
            Write-CleanupLog -Level INFO -Message "Already removed: $DisplayName";
            Return;
        };

        $RegistryPath = $Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', '';
        $RegistryPath = $RegistryPath -replace '^Registry::', '';

        If ($RegistryPath -match '^HKEY_LOCAL_MACHINE\\') {
            $RegistryPath = $RegistryPath -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM\';
        }
        ElseIf ($RegistryPath -match '^HKEY_USERS\\') {
            $RegistryPath = $RegistryPath -replace '^HKEY_USERS\\', 'HKU\';
        }

        If ($RegistryPath -match '^(HKLM|HKU)\\') {
            $RegDelete = reg.exe delete $RegistryPath /f 2>&1;

            If ($LASTEXITCODE -eq 0) {
                Write-CleanupLog -Level SUCCESS -Message "Removed with reg.exe: $DisplayName";
                Return;
            };

            If (-not (Test-Path -Path $Path)) {
                Write-CleanupLog -Level INFO -Message "Already removed: $DisplayName";
                Return;
            };

            Write-CleanupLog -Level ERROR -Message "Failed to remove ${DisplayName}: $($_.Exception.Message); reg.exe: $RegDelete";
        }
        Else {
            Write-CleanupLog -Level ERROR -Message "Failed to remove ${DisplayName}: $($_.Exception.Message)";
        }
    }
};

Function Invoke-PnpDeviceRemoval {
    [CmdletBinding()]
    Param(
        [Parameter(
            Mandatory = $True
        )]
        [ValidateNotNullOrEmpty()]
        [String]
        $InstanceId,

        [Parameter(
            Mandatory = $False
        )]
        [ValidateNotNullOrEmpty()]
        [String]
        $DisplayName = $InstanceId
    )

    Write-CleanupLog -Level WARN -Message "Removing PnP device: $DisplayName [$InstanceId]";

    Try {
        $Result = & pnputil.exe /remove-device $InstanceId /subtree /force 2>&1 | Out-String;
        $Result = $Result.Trim();

        If ($Result) {
            Write-CleanupLog -Level INFO -Message "pnputil result: $Result";
        };

        If ($LASTEXITCODE -eq 0) {
            Write-CleanupLog -Level SUCCESS -Message "pnputil removed device: $InstanceId";
            Return $True;
        };

        Write-CleanupLog -Level WARN -Message "pnputil exit code $LASTEXITCODE for $InstanceId";
    }
    Catch {
        Write-CleanupLog -Level WARN -Message "pnputil failed for ${InstanceId}: $($_.Exception.Message)";
    }

    Return $False;
};

#endregion Functions

#region Verify Required Services

Write-Host -ForegroundColor DarkCyan '=== Verifying Required Services ===';

$RequiredServices = @(
    'RpcSs',
    'DcomLaunch',
    'RpcEptMapper',
    'PlugPlay',
    'DeviceInstall',
    'DsmSvc',
    'DeviceAssociationService',
    'Spooler'
);

ForEach ($ServiceName in $RequiredServices) {
    $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue;

    If (-not $Service) {
        Write-CleanupLog -Level WARN -Message "Service not found: $ServiceName";
        Continue;
    };

    Write-CleanupLog -Level INFO -Message "Service $ServiceName status: $($Service.Status)";

    If ($Service.Status -ne 'Running') {
        Write-CleanupLog -Level WARN -Message "Starting service: $ServiceName";

        Try {
            Start-Service -Name $ServiceName -ErrorAction Stop;
            Write-CleanupLog -Level SUCCESS -Message "Started: $ServiceName";
        }
        Catch {
            Write-CleanupLog -Level ERROR -Message "Could not start ${ServiceName}: $($_.Exception.Message)";
        }
    };
};

#endregion Verify Required Services

#region Remove Matched Printer Objects

Write-Host -ForegroundColor DarkCyan '=== Removing Stale Printer Objects ===';

$MatchedPrinters = Get-Printer -ErrorAction SilentlyContinue | Where-Object {
    $SearchText = "$($_.Name) $($_.ComputerName) $($_.PortName) $($_.DriverName) $($_.Description)";

    Test-MatchesPattern -Text $SearchText -PatternList $Patterns;
};

If (-not $MatchedPrinters) {
    Write-CleanupLog -Level INFO -Message 'No matching printer objects found.';
}
Else {
    ForEach ($Printer in $MatchedPrinters) {
        Write-CleanupLog -Level WARN -Message "Removing printer: $($Printer.Name)";

        Try {
            & rundll32.exe printui.dll, PrintUIEntry /dn /n "$($Printer.Name)" 2>&1 | Out-Null;
        }
        Catch {
            Write-CleanupLog -Level WARN -Message "PrintUIEntry failed for $($Printer.Name): $($_.Exception.Message)";
        }

        Try {
            Remove-Printer -Name $Printer.Name -ErrorAction Stop;
            Write-CleanupLog -Level SUCCESS -Message "Removed printer: $($Printer.Name)";
        }
        Catch {
            Write-CleanupLog -Level WARN -Message "Remove-Printer failed for $($Printer.Name): $($_.Exception.Message)";
        }
    };
}

#endregion Remove Matched Printer Objects

#region Remove Matched PnP Entities

Write-Host -ForegroundColor DarkCyan '=== Removing Stale PnP Printer Devices ===';

$MatchedPnpEntities = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
    $SearchText = "$($_.Name) $($_.Caption) $($_.Description) $($_.PNPDeviceID)";
    $IsPrinterDevice = ($_.PNPClass -eq 'Printer') -or ($_.PNPDeviceID -like 'SWD\PRINTENUM\*');
    $IsPhantomDevice = $_.ConfigManagerErrorCode -eq 45;

    (Test-MatchesPattern -Text $SearchText -PatternList $Patterns) -or ($IsPrinterDevice -and $IsPhantomDevice);
};

If (-not $MatchedPnpEntities) {
    Write-CleanupLog -Level INFO -Message 'No matching or phantom Win32_PnPEntity devices found.';
}
Else {
    ForEach ($Entity in $MatchedPnpEntities) {
        If ($Entity.PNPDeviceID) {
            If ($Entity.ConfigManagerErrorCode -eq 45) {
                $Reason = 'phantom';
            }
            Else {
                $Reason = 'matched';
            }

            Invoke-PnpDeviceRemoval -InstanceId $Entity.PNPDeviceID -DisplayName "$Reason PnP entity: $($Entity.Name)" | Out-Null;
        };
    };
}

#endregion Remove Matched PnP Entities

#region Remove Matched PnpDevice Entries

Write-Host -ForegroundColor DarkCyan '=== Removing Stale PnpDevice Entries ===';

$MatchedPnpDevices = Get-PnpDevice -Class Printer -ErrorAction SilentlyContinue | Where-Object {
    $SearchText = "$($_.FriendlyName) $($_.Name) $($_.InstanceId)";

    (Test-MatchesPattern -Text $SearchText -PatternList $Patterns) -or ($_.Problem -eq 'CM_PROB_PHANTOM');
};

If (-not $MatchedPnpDevices) {
    Write-CleanupLog -Level INFO -Message 'No matching or phantom PnpDevice printer entries found.';
}
Else {
    ForEach ($Device in $MatchedPnpDevices) {
        If ($Device.Problem -eq 'CM_PROB_PHANTOM') {
            $Reason = 'phantom';
        }
        Else {
            $Reason = 'matched';
        }

        Invoke-PnpDeviceRemoval -InstanceId $Device.InstanceId -DisplayName "$Reason PnpDevice: $($Device.FriendlyName)" | Out-Null;
    };
}

#endregion Remove Matched PnpDevice Entries

#region Stop Print Services

Write-Host -ForegroundColor DarkCyan '=== Stopping Print Services ===';

Write-CleanupLog -Level WARN -Message 'Stopping Spooler';

Try {
    Stop-Service -Name 'Spooler' -Force -ErrorAction Stop;
    Write-CleanupLog -Level SUCCESS -Message 'Stopped Spooler';
}
Catch {
    Write-CleanupLog -Level WARN -Message "Could not stop Spooler cleanly: $($_.Exception.Message)";
}

#endregion Stop Print Services

#region Remove PRINTENUM Registry Remnants

Write-Host -ForegroundColor DarkCyan '=== Removing PRINTENUM Registry Remnants ===';

$PrintEnumPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\PRINTENUM';

If (Test-Path -Path $PrintEnumPath) {
    $KeysToRemove = Get-ChildItem -Path $PrintEnumPath -ErrorAction SilentlyContinue | Where-Object {
        Test-RegistryTreeMatchesPattern -Path $_.PSPath -PatternList $Patterns;
    } | Sort-Object -Property Name -Descending;

    If (-not $KeysToRemove) {
        Write-CleanupLog -Level INFO -Message 'No matching PRINTENUM keys found.';
    }
    Else {
        ForEach ($Key in $KeysToRemove) {
            $InstanceId = "SWD\PRINTENUM\$($Key.PSChildName)";

            Write-CleanupLog -Level WARN -Message "Removing PRINTENUM key: $($Key.Name)";

            $RemovedByPnp = Invoke-PnpDeviceRemoval -InstanceId $InstanceId -DisplayName 'PRINTENUM registry device';

            If (-not (Test-Path -Path $Key.PSPath)) {
                Write-CleanupLog -Level INFO -Message "PRINTENUM key removed by PnP cleanup: $($Key.Name)";
                Continue;
            };

            If ($RemovedByPnp) {
                Write-CleanupLog -Level WARN -Message "PRINTENUM key still visible after pnputil. Leaving protected Enum key for Windows to reconcile: $($Key.Name)";
                Continue;
            };

            Write-CleanupLog -Level WARN -Message "pnputil did not remove PRINTENUM device. Attempting registry fallback: $($Key.Name)";

            Remove-RegistryKeyIfPresent -Path $Key.PSPath -DisplayName $Key.Name;
        };
    }
}
Else {
    Write-CleanupLog -Level INFO -Message 'PRINTENUM path not found. Skipping.';
}

#endregion Remove PRINTENUM Registry Remnants

#region Remove Machine-Level Print Connection Registry Keys

Write-Host -ForegroundColor DarkCyan '=== Removing Machine-Level Print Connection Registry Keys ===';

$MachinePrintConnectionsPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Connections';

If (Test-Path -Path $MachinePrintConnectionsPath) {
    $MachineConnectionKeysToRemove = Get-ChildItem -Path $MachinePrintConnectionsPath -ErrorAction SilentlyContinue | Where-Object {
        Test-RegistryTreeMatchesPattern -Path $_.PSPath -PatternList $Patterns;
    } | Sort-Object -Property Name -Descending;

    If (-not $MachineConnectionKeysToRemove) {
        Write-CleanupLog -Level INFO -Message 'No matching machine-level Print\Connections keys found.';
    }
    Else {
        ForEach ($Key in $MachineConnectionKeysToRemove) {
            Write-CleanupLog -Level WARN -Message "Removing machine-level Print\Connections key: $($Key.Name)";

            Remove-RegistryKeyIfPresent -Path $Key.PSPath -DisplayName $Key.Name;
        };
    }
}
Else {
    Write-CleanupLog -Level INFO -Message 'Machine-level Print\Connections path not found. Skipping.';
}

#endregion Remove Machine-Level Print Connection Registry Keys

#region Remove Machine-Level Printer Registry Keys

Write-Host -ForegroundColor DarkCyan '=== Removing Machine-Level Printer Registry Keys ===';

$MachinePrintPrintersPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Printers';

If (Test-Path -Path $MachinePrintPrintersPath) {
    $MachinePrinterKeysToRemove = Get-ChildItem -Path $MachinePrintPrintersPath -ErrorAction SilentlyContinue | Where-Object {
        Test-RegistryTreeMatchesPattern -Path $_.PSPath -PatternList $Patterns;
    } | Sort-Object -Property Name -Descending;

    If (-not $MachinePrinterKeysToRemove) {
        Write-CleanupLog -Level INFO -Message 'No matching machine-level Print\Printers keys found.';
    }
    Else {
        ForEach ($Key in $MachinePrinterKeysToRemove) {
            Write-CleanupLog -Level WARN -Message "Removing machine-level Print\Printers key: $($Key.Name)";

            Remove-RegistryKeyIfPresent -Path $Key.PSPath -DisplayName $Key.Name;
        };
    }
}
Else {
    Write-CleanupLog -Level INFO -Message 'Machine-level Print\Printers path not found. Skipping.';
}

#endregion Remove Machine-Level Printer Registry Keys

#region Clean User Hive Printer Connection Keys

Write-Host -ForegroundColor DarkCyan '=== Cleaning User-Hive Printer Connection Keys ===';

$UserProfileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList';

$UserProfiles = Get-ChildItem -Path $UserProfileListPath -ErrorAction SilentlyContinue | Where-Object {
    $_.PSChildName -match '^S-1-5-21-';
} | ForEach-Object {
    $Sid = $_.PSChildName;
    $UserProfilePath = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath;

    [PSCustomObject]@{
        SID         = $Sid;
        ProfilePath = $UserProfilePath;
    };
} | Where-Object {
    $_.ProfilePath -and (Test-Path -Path $_.ProfilePath);
};

ForEach ($UserProfile in $UserProfiles) {
    $Sid = $UserProfile.SID;
    $NtUserDatPath = Join-Path -Path $UserProfile.ProfilePath -ChildPath 'NTUSER.DAT';
    $MountKey = "HKU_TEMP_$Sid";
    $MountPath = "Registry::HKEY_USERS\$MountKey";
    $AlreadyLoaded = Test-Path -Path "Registry::HKEY_USERS\$Sid";

    If (-not (Test-Path -Path $NtUserDatPath)) {
        Write-CleanupLog -Level WARN -Message "NTUSER.DAT not found for $Sid. Skipping.";
        Continue;
    };

    $HiveMounted = $False;

    If (-not $AlreadyLoaded) {
        Write-CleanupLog -Level INFO -Message "Loading hive: $NtUserDatPath to $MountKey";

        $RegLoad = reg.exe load "HKEY_USERS\$MountKey" "$NtUserDatPath" 2>&1;

        If ($LASTEXITCODE -ne 0) {
            Write-CleanupLog -Level WARN -Message "Could not load hive for $Sid. It may be in use or locked. Result: $RegLoad";
            Continue;
        };

        $HiveMounted = $True;
    }
    Else {
        $MountPath = "Registry::HKEY_USERS\$Sid";

        Write-CleanupLog -Level INFO -Message "Hive already loaded for $Sid. Using live path.";
    }

    $ConnectionsPath = "$MountPath\Printers\Connections";

    If (Test-Path -Path $ConnectionsPath) {
        $KeysToRemove = Get-ChildItem -Path $ConnectionsPath -ErrorAction SilentlyContinue | Where-Object {
            Test-RegistryTreeMatchesPattern -Path $_.PSPath -PatternList $Patterns;
        };

        If (-not $KeysToRemove) {
            Write-CleanupLog -Level INFO -Message "No matching connection keys for $Sid.";
        }
        Else {
            ForEach ($Key in $KeysToRemove) {
                Write-CleanupLog -Level WARN -Message "Removing connection key [$Sid]: $($Key.PSChildName)";

                Remove-RegistryKeyIfPresent -Path $Key.PSPath -DisplayName $Key.Name;
            }
        }
    }
    Else {
        Write-CleanupLog -Level INFO -Message "No Printers\Connections key for $Sid. Skipping.";
    }

    If ($HiveMounted) {
        [System.GC]::Collect();
        [System.GC]::WaitForPendingFinalizers();

        $RegUnload = reg.exe unload "HKEY_USERS\$MountKey" 2>&1;

        If ($LASTEXITCODE -ne 0) {
            Write-CleanupLog -Level WARN -Message "Could not unload hive for ${Sid}: $RegUnload";
        }
        Else {
            Write-CleanupLog -Level INFO -Message "Unloaded hive for $Sid.";
        }
    };
};

#endregion Clean User Hive Printer Connection Keys

#region Clear Client Side Rendering Print Provider Cache

Write-Host -ForegroundColor DarkCyan '=== Clearing CSR Print Provider Cache ===';

$CsrBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Providers\Client Side Rendering Print Provider';

If (Test-Path -Path $CsrBase) {
    $CsrMatched = Get-ChildItem -Path $CsrBase -Recurse -ErrorAction SilentlyContinue | Where-Object {
        $SearchText = Get-RegistryItemSearchText -RegistryItem $_;

        Test-MatchesPattern -Text $SearchText -PatternList $Patterns;
    } | Sort-Object -Property Name -Descending;

    If (-not $CsrMatched) {
        Write-CleanupLog -Level INFO -Message 'No pattern-matched CSR keys found.';
    }
    Else {
        ForEach ($Key in $CsrMatched) {
            Write-CleanupLog -Level WARN -Message "Removing CSR key: $($Key.Name)";

            Remove-RegistryKeyIfPresent -Path $Key.PSPath -DisplayName $Key.Name;
        };
    }

    $CsrServersPath = "$CsrBase\Servers";

    If (Test-Path -Path $CsrServersPath) {
        Get-ChildItem -Path $CsrServersPath -ErrorAction SilentlyContinue | ForEach-Object {
            Write-CleanupLog -Level WARN -Message "Removing CSR server key: $($_.Name)";

            Remove-RegistryKeyIfPresent -Path $_.PSPath -DisplayName $_.Name;
        };

        Write-CleanupLog -Level SUCCESS -Message 'CSR Servers subkey cleared.';
    }
    Else {
        Write-CleanupLog -Level INFO -Message 'CSR Servers subkey not found. Skipping.';
    }
}
Else {
    Write-CleanupLog -Level INFO -Message 'CSR Print Provider path not found. Skipping.';
}

#endregion Clear Client Side Rendering Print Provider Cache

#region Clear Device Metadata Cache

Write-Host -ForegroundColor DarkCyan '=== Clearing Device Metadata Cache ===';

$CachePaths = @(
    "$env:LOCALAPPDATA\Microsoft\Device Metadata\dmrccache\*",
    'C:\ProgramData\Microsoft\Windows\DeviceMetadataCache\*'
);

ForEach ($CachePath in $CachePaths) {
    Write-CleanupLog -Level INFO -Message "Clearing: $CachePath";

    Remove-Item -Path $CachePath -Recurse -Force -ErrorAction SilentlyContinue;
};

#endregion Clear Device Metadata Cache

#region Clear Chrome Print Preview Cache

Write-Host -ForegroundColor DarkCyan '=== Clearing Chrome Print Preview Cache ===';

$ChromeProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object {
    (-not $_.Special) -and
    $_.LocalPath -and
    ($_.LocalPath -like 'C:\Users\*');
};

ForEach ($ChromeUserProfile in $ChromeProfiles) {
    $UserPath = $ChromeUserProfile.LocalPath;
    $ChromeRoot = Join-Path -Path $UserPath -ChildPath 'AppData\Local\Google\Chrome\User Data';

    If (-not (Test-Path -Path $ChromeRoot)) {
        Write-CleanupLog -Level INFO -Message "Chrome profile root not found for $UserPath. Skipping.";
        Continue;
    };

    $ChromeProfileDirs = Get-ChildItem -Path $ChromeRoot -Directory -ErrorAction SilentlyContinue | Where-Object {
        Test-Path -Path (Join-Path -Path $_.FullName -ChildPath 'Preferences');
    };

    If (-not $ChromeProfileDirs) {
        Write-CleanupLog -Level INFO -Message "No Chrome Preferences files found for $UserPath.";
        Continue;
    };

    ForEach ($ChromeProfileDir in $ChromeProfileDirs) {
        $PrefPath = Join-Path -Path $ChromeProfileDir.FullName -ChildPath 'Preferences';

        Try {
            $Prefs = Get-Content -Path $PrefPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop;
            $Sticky = $Prefs.printing.print_preview_sticky_settings.appState;

            If (-not $Sticky) {
                Write-CleanupLog -Level INFO -Message "No Chrome print preview cache in $PrefPath.";
                Continue;
            };

            $AppState = $Sticky | ConvertFrom-Json -ErrorAction Stop;

            If (-not $AppState.recentDestinations) {
                Write-CleanupLog -Level INFO -Message "No Chrome recent print destinations in $PrefPath.";
                Continue;
            };

            $Before = @($AppState.recentDestinations).Count;

            $AppState.recentDestinations = @(
                $AppState.recentDestinations | Where-Object {
                    $SearchText = "$($_.id) $($_.displayName)";

                    -not (Test-MatchesPattern -Text $SearchText -PatternList $Patterns);
                };
            );

            $After = @($AppState.recentDestinations).Count;
            $Removed = $Before - $After;

            If ($Removed -le 0) {
                Write-CleanupLog -Level INFO -Message "No matched Chrome print destinations in $PrefPath.";
                Continue;
            };

            Copy-Item -Path $PrefPath -Destination "$PrefPath.bak" -Force -ErrorAction Stop;

            $Prefs.printing.print_preview_sticky_settings.appState = $AppState | ConvertTo-Json -Depth 20 -Compress;

            $Prefs | ConvertTo-Json -Depth 100 -Compress | Set-Content -Path $PrefPath -Encoding UTF8 -ErrorAction Stop;

            Write-CleanupLog -Level SUCCESS -Message "Removed $Removed Chrome print destination(s): $PrefPath";
        }
        Catch {
            Write-CleanupLog -Level ERROR -Message "Failed to clean Chrome print cache in ${PrefPath}: $($_.Exception.Message)";
        }
    };
};

#endregion Clear Chrome Print Preview Cache

#region Restart Services

Write-Host -ForegroundColor DarkCyan '=== Restarting Services ===';

ForEach ($ServiceName in @('Spooler', 'DeviceAssociationService')) {
    Write-CleanupLog -Level INFO -Message "Starting: $ServiceName";

    Try {
        Start-Service -Name $ServiceName -ErrorAction Stop;

        Write-CleanupLog -Level SUCCESS -Message "Started: $ServiceName";
    }
    Catch {
        Write-CleanupLog -Level ERROR -Message "Could not start ${ServiceName}: $($_.Exception.Message)";
    }
};

#endregion Restart Services

#region Complete

Write-Host -ForegroundColor DarkCyan '=== Complete ===';

Write-CleanupLog -Level SUCCESS -Message 'Cleanup complete. Reboot before retesting Add Device or printer discovery.';

#endregion Complete