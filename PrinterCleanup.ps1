#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes stale Windows printer objects, PnP devices, and related registry
    artifacts that match caller-supplied patterns.
.DESCRIPTION
    Performs a stale-printer cleanup in the correct service stop/start order:
      1. Verify required device/RPC services are running
      2. Stop Spooler + DeviceAssociationService
      3. Remove matched printers (Remove-Printer + rundll32 PrintUIEntry)
      4. Remove matched Win32_PnPEntity devices via pnputil
      5. Remove matched Get-PnpDevice entries (PRINTENUM / SWD class)
      6. Remove matched PRINTENUM registry keys
      7. Remove matched machine-level Print\Connections registry keys
      8. Remove matched machine-level Print\Printers registry keys
      9. Mount all local user hives, remove matched Printers\Connections keys, unmount
     10. Clear Client Side Rendering Print Provider cache (pattern + Servers)
     11. Clear Device Metadata filesystem caches
     12. Remove matched Chrome print preview cached destinations
     13. Restart services
.PARAMETER Patterns
    Strings to match against printer/device names, captions, port names, driver
    names, instance IDs, and registry key names. Matched against all relevant
    fields using -like wildcard comparison.
.PARAMETER LogDirectory
    Directory where the cleanup log should be written.
.EXAMPLE
    .\Remove-StaleServerPrinters.ps1 -Patterns "OLD-PRINT01","\\OLD-PRINT01"
.EXAMPLE
    .\Remove-StaleServerPrinters.ps1 -Patterns "OLD-PRINT01","OLD-PRINT01.contoso.com","Front Desk"
.NOTES
    Updated: 2026-05-15
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Patterns,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$LogDirectory = "$env:ProgramData\PrinterCleanup"
)

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$LogPath = Join-Path -Path $LogDirectory -ChildPath 'Remove-StaleServerPrinters.log'

Function Write-CleanupLog {
    [CmdletBinding()]
    param(
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LogPath -Value $entry -ErrorAction SilentlyContinue
    switch ($Level) {
        'INFO' { Write-Host -ForegroundColor DarkGray  "[i] $Message" }
        'SUCCESS' { Write-Host -ForegroundColor Green     "[+] $Message" }
        'WARN' { Write-Host -ForegroundColor Yellow    "[!] $Message" }
        'ERROR' { Write-Host -ForegroundColor Red       "[X] $Message" }
    }
};

Function Test-MatchesPattern {
    [CmdletBinding()]
    param(
        [string]$Text,
        [string[]]$PatternList
    )
    foreach ($p in $PatternList) {
        if ($Text -like "*$p*") { return $true }
    }
    return $false
};

Function Get-RegistryItemSearchText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$RegistryItem
    )

    $textParts = @(
        $RegistryItem.Name,
        $RegistryItem.PSChildName
    )

    try {
        $properties = Get-ItemProperty -Path $RegistryItem.PSPath -ErrorAction Stop

        foreach ($property in $properties.PSObject.Properties) {
            if ($property.Name -like 'PS*') { continue }

            $valueText = if ($property.Value -is [array]) {
                $property.Value -join ' '
            }
            else {
                $property.Value
            }

            $textParts += "$($property.Name) $valueText"
        }
    }
    catch {
        # Some protected registry keys cannot be read. Key name matching still applies.
    }

    return ($textParts -join ' ')
};

Function Test-RegistryTreeMatchesPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$PatternList
    )

    if (-not (Test-Path $Path)) { return $false }

    $items = @()

    try {
        $items += Get-Item -Path $Path -ErrorAction Stop
        $items += Get-ChildItem -Path $Path -Recurse -ErrorAction SilentlyContinue
    }
    catch {
        return $false
    }

    foreach ($item in $items) {
        $text = Get-RegistryItemSearchText -RegistryItem $item
        if (Test-MatchesPattern -Text $text -PatternList $PatternList) {
            return $true
        }
    }

    return $false
};

# ---------------------------------------------------------------------------
# 1. Required services — verify and start if needed
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Verifying Required Services ==='

$RequiredServices = @(
    'RpcSs',
    'DcomLaunch',
    'RpcEptMapper',
    'PlugPlay',
    'DeviceInstall',
    'DsmSvc',
    'DeviceAssociationService'
)

foreach ($ServiceName in $RequiredServices) {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-CleanupLog -Level WARN -Message "Service not found: $ServiceName"
        continue
    }
    Write-CleanupLog -Level INFO -Message "Service $ServiceName — status: $($svc.Status)"
    if ($svc.Status -ne 'Running') {
        Write-CleanupLog -Level WARN -Message "Starting service: $ServiceName"
        try {
            Start-Service -Name $ServiceName -ErrorAction Stop
            Write-CleanupLog -Level SUCCESS -Message "Started: $ServiceName"
        }
        catch {
            Write-CleanupLog -Level ERROR -Message "Could not start ${ServiceName}: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Stop Spooler and DeviceAssociationService before all removals
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Stopping Print Services ==='

Write-CleanupLog -Level WARN -Message 'Stopping Spooler'
Stop-Service -Name 'Spooler' -Force -ErrorAction SilentlyContinue

Write-CleanupLog -Level WARN -Message 'Stopping DeviceAssociationService'
Stop-Service -Name 'DeviceAssociationService' -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# 3. Remove matched printers (Win32 printer objects)
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Removing Stale Printer Objects ==='

$MatchedPrinters = Get-Printer -ErrorAction SilentlyContinue | Where-Object {
    $text = "$($_.Name) $($_.ComputerName) $($_.PortName) $($_.DriverName) $($_.Description)"
    Test-MatchesPattern -Text $text -PatternList $Patterns
}

if (-not $MatchedPrinters) {
    Write-CleanupLog -Level INFO -Message 'No matching printer objects found.'
}
else {
    foreach ($printer in $MatchedPrinters) {
        Write-CleanupLog -Level WARN -Message "Removing printer: $($printer.Name)"
        rundll32 printui.dll, PrintUIEntry /dn /n "$($printer.Name)"
        Remove-Printer -Name $printer.Name -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# 4. Remove matched PnP entities (Win32_PnPEntity / pnputil)
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Removing Stale PnP Printer Devices ==='

$MatchedPnpEntities = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
Where-Object {
    $text = "$($_.Name) $($_.Caption) $($_.Description) $($_.PNPDeviceID)"
    Test-MatchesPattern -Text $text -PatternList $Patterns
}

if (-not $MatchedPnpEntities) {
    Write-CleanupLog -Level INFO -Message 'No matching Win32_PnPEntity devices found.'
}
else {
    foreach ($entity in $MatchedPnpEntities) {
        if ($entity.PNPDeviceID) {
            Write-CleanupLog -Level WARN -Message "Removing PnP entity: $($entity.Name) [$($entity.PNPDeviceID)]"
            $result = pnputil.exe /remove-device "$($entity.PNPDeviceID)" /subtree /force
            Write-CleanupLog -Level INFO -Message "pnputil result: $result"
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Remove matched Get-PnpDevice entries (PRINTENUM / SWD class)
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Removing Stale PnpDevice Entries ==='

$MatchedPnpDevices = Get-PnpDevice -Class Printer -ErrorAction SilentlyContinue |
Where-Object {
    $text = "$($_.FriendlyName) $($_.Name) $($_.InstanceId)"
    Test-MatchesPattern -Text $text -PatternList $Patterns
}

if (-not $MatchedPnpDevices) {
    Write-CleanupLog -Level INFO -Message 'No matching PnpDevice printer entries found.'
}
else {
    foreach ($device in $MatchedPnpDevices) {
        Write-CleanupLog -Level WARN -Message "Removing PnpDevice: $($device.FriendlyName) [$($device.InstanceId)]"
        $result = pnputil.exe /remove-device "$($device.InstanceId)" /subtree /force
        Write-CleanupLog -Level INFO -Message "pnputil result: $result"
    }
}

# ---------------------------------------------------------------------------
# 6. Remove matched PRINTENUM registry keys
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Removing PRINTENUM Registry Remnants ==='

$PrintEnumPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\SWD\PRINTENUM'

if (Test-Path $PrintEnumPath) {
    $keysToRemove = Get-ChildItem -Path $PrintEnumPath -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $text = Get-RegistryItemSearchText -RegistryItem $_
        Test-MatchesPattern -Text $text -PatternList $Patterns
    } |
    Sort-Object Name -Descending

    if (-not $keysToRemove) {
        Write-CleanupLog -Level INFO -Message 'No matching PRINTENUM keys found.'
    }
    else {
        foreach ($key in $keysToRemove) {
            Write-CleanupLog -Level WARN -Message "Removing PRINTENUM key: $($key.Name)"
            try {
                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                Write-CleanupLog -Level SUCCESS -Message "Removed: $($key.Name)"
            }
            catch {
                Write-CleanupLog -Level ERROR -Message "Failed to remove $($key.Name): $($_.Exception.Message)"
            }
        }
    }
}
else {
    Write-CleanupLog -Level INFO -Message 'PRINTENUM path not found — skipping.'
}

# ---------------------------------------------------------------------------
# 7. Remove matched machine-level Print\Connections registry keys
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Removing Machine-Level Print Connection Registry Keys ==='

$MachinePrintConnectionsPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Connections'

if (Test-Path $MachinePrintConnectionsPath) {
    $machineConnectionKeysToRemove = Get-ChildItem -Path $MachinePrintConnectionsPath -ErrorAction SilentlyContinue |
    Where-Object {
        Test-RegistryTreeMatchesPattern -Path $_.PSPath -PatternList $Patterns
    } |
    Sort-Object Name -Descending

    if (-not $machineConnectionKeysToRemove) {
        Write-CleanupLog -Level INFO -Message 'No matching machine-level Print\Connections keys found.'
    }
    else {
        foreach ($key in $machineConnectionKeysToRemove) {
            Write-CleanupLog -Level WARN -Message "Removing machine-level Print\Connections key: $($key.Name)"
            try {
                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                Write-CleanupLog -Level SUCCESS -Message "Removed: $($key.Name)"
            }
            catch {
                Write-CleanupLog -Level ERROR -Message "Failed to remove $($key.Name): $($_.Exception.Message)"
            }
        }
    }
}
else {
    Write-CleanupLog -Level INFO -Message 'Machine-level Print\Connections path not found — skipping.'
}

# ---------------------------------------------------------------------------
# 8. Remove matched machine-level Print\Printers registry keys
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Removing Machine-Level Printer Registry Keys ==='

$MachinePrintPrintersPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Printers'

if (Test-Path $MachinePrintPrintersPath) {
    $machinePrinterKeysToRemove = Get-ChildItem -Path $MachinePrintPrintersPath -ErrorAction SilentlyContinue |
    Where-Object {
        Test-RegistryTreeMatchesPattern -Path $_.PSPath -PatternList $Patterns
    } |
    Sort-Object Name -Descending

    if (-not $machinePrinterKeysToRemove) {
        Write-CleanupLog -Level INFO -Message 'No matching machine-level Print\Printers keys found.'
    }
    else {
        foreach ($key in $machinePrinterKeysToRemove) {
            Write-CleanupLog -Level WARN -Message "Removing machine-level Print\Printers key: $($key.Name)"
            try {
                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction Stop
                Write-CleanupLog -Level SUCCESS -Message "Removed: $($key.Name)"
            }
            catch {
                Write-CleanupLog -Level ERROR -Message "Failed to remove $($key.Name): $($_.Exception.Message)"
            }
        }
    }
}
else {
    Write-CleanupLog -Level INFO -Message 'Machine-level Print\Printers path not found — skipping.'
}

# ---------------------------------------------------------------------------
# 9. Mount all local user hives, clean Printers\Connections, unmount
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Cleaning User-Hive Printer Connection Keys ==='

# Collect profile paths from the registry — works regardless of who is logged on
$ProfileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
$UserProfiles = Get-ChildItem -Path $ProfileListPath -ErrorAction SilentlyContinue |
Where-Object { $_.PSChildName -match '^S-1-5-21-' } |
ForEach-Object {
    $sid = $_.PSChildName
    $profilePath = (Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
    [PSCustomObject]@{ SID = $sid; ProfilePath = $profilePath }
} |
Where-Object { $_.ProfilePath -and (Test-Path $_.ProfilePath) }

foreach ($profile in $UserProfiles) {
    $sid = $profile.SID
    $ntuserdatPath = Join-Path $profile.ProfilePath 'NTUSER.DAT'
    $mountKey = "HKU_TEMP_$sid"
    $mountPath = "Registry::HKEY_USERS\$mountKey"
    $alreadyLoaded = Test-Path "Registry::HKEY_USERS\$sid"

    if (-not (Test-Path $ntuserdatPath)) {
        Write-CleanupLog -Level WARN -Message "NTUSER.DAT not found for $sid — skipping."
        continue
    }

    # Mount hive only if not already loaded (e.g. active session)
    $hiveMounted = $false
    if (-not $alreadyLoaded) {
        Write-CleanupLog -Level INFO -Message "Loading hive: $ntuserdatPath -> $mountKey"
        $regLoad = reg.exe load "HKEY_USERS\$mountKey" "$ntuserdatPath" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-CleanupLog -Level WARN -Message "Could not load hive for $sid (in use or locked): $regLoad"
            continue
        }
        $hiveMounted = $true
    }
    else {
        # Already loaded — use the real SID path directly
        $mountPath = "Registry::HKEY_USERS\$sid"
        Write-CleanupLog -Level INFO -Message "Hive already loaded for $sid — using live path."
    }

    $connectionsPath = "$mountPath\Printers\Connections"

    if (Test-Path $connectionsPath) {
        $keysToRemove = Get-ChildItem -Path $connectionsPath -ErrorAction SilentlyContinue |
        Where-Object {
            Test-RegistryTreeMatchesPattern -Path $_.PSPath -PatternList $Patterns
        }

        if (-not $keysToRemove) {
            Write-CleanupLog -Level INFO -Message "No matching connection keys for $sid."
        }
        else {
            foreach ($key in $keysToRemove) {
                Write-CleanupLog -Level WARN -Message "Removing connection key [$sid]: $($key.PSChildName)"
                Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        Write-CleanupLog -Level INFO -Message "No Printers\Connections key for $sid — skipping."
    }

    # Unload only hives we mounted (never unload an active session)
    if ($hiveMounted) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        $regUnload = reg.exe unload "HKEY_USERS\$mountKey" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-CleanupLog -Level WARN -Message "Could not unload hive for ${sid}: $regUnload"
        }
        else {
            Write-CleanupLog -Level INFO -Message "Unloaded hive for $sid."
        }
    }
}

# ---------------------------------------------------------------------------
# 10. Clear Client Side Rendering Print Provider cache
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Clearing CSR Print Provider Cache ==='

$CsrBase = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Print\Providers\Client Side Rendering Print Provider'

if (Test-Path $CsrBase) {
    $csrMatched = Get-ChildItem -Path $CsrBase -Recurse -ErrorAction SilentlyContinue |
    Where-Object {
        $text = Get-RegistryItemSearchText -RegistryItem $_
        Test-MatchesPattern -Text $text -PatternList $Patterns
    } |
    Sort-Object Name -Descending

    if (-not $csrMatched) {
        Write-CleanupLog -Level INFO -Message 'No pattern-matched CSR keys found.'
    }
    else {
        foreach ($key in $csrMatched) {
            Write-CleanupLog -Level WARN -Message "Removing CSR key: $($key.Name)"
            Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $CsrServersPath = "$CsrBase\Servers"
    if (Test-Path $CsrServersPath) {
        Get-ChildItem -Path $CsrServersPath -ErrorAction SilentlyContinue |
        ForEach-Object {
            Write-CleanupLog -Level WARN -Message "Removing CSR server key: $($_.Name)"
            Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-CleanupLog -Level SUCCESS -Message 'CSR Servers subkey cleared.'
    }
    else {
        Write-CleanupLog -Level INFO -Message 'CSR Servers subkey not found — skipping.'
    }
}
else {
    Write-CleanupLog -Level INFO -Message 'CSR Print Provider path not found — skipping.'
}

# ---------------------------------------------------------------------------
# 11. Clear Device Metadata filesystem caches
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Clearing Device Metadata Cache ==='

$CachePaths = @(
    "$env:LOCALAPPDATA\Microsoft\Device Metadata\dmrccache\*",
    'C:\ProgramData\Microsoft\Windows\DeviceMetadataCache\*'
)

foreach ($cachePath in $CachePaths) {
    Write-CleanupLog -Level INFO -Message "Clearing: $cachePath"
    Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 12. Remove matched Chrome print preview cached destinations
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Clearing Chrome Print Preview Cache ==='

$ChromeProfiles = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
Where-Object {
    (-not $_.Special) -and
    $_.LocalPath -and
    ($_.LocalPath -like 'C:\Users\*')
}

foreach ($chromeUserProfile in $ChromeProfiles) {
    $userPath = $chromeUserProfile.LocalPath
    $chromeRoot = Join-Path -Path $userPath -ChildPath 'AppData\Local\Google\Chrome\User Data'

    if (-not (Test-Path $chromeRoot)) {
        Write-CleanupLog -Level INFO -Message "Chrome profile root not found for $userPath — skipping."
        continue
    }

    $chromeProfileDirs = Get-ChildItem -Path $chromeRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        Test-Path (Join-Path -Path $_.FullName -ChildPath 'Preferences')
    }

    if (-not $chromeProfileDirs) {
        Write-CleanupLog -Level INFO -Message "No Chrome Preferences files found for $userPath."
        continue
    }

    foreach ($chromeProfileDir in $chromeProfileDirs) {
        $prefPath = Join-Path -Path $chromeProfileDir.FullName -ChildPath 'Preferences'

        try {
            $prefs = Get-Content -Path $prefPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $sticky = $prefs.printing.print_preview_sticky_settings.appState

            if (-not $sticky) {
                Write-CleanupLog -Level INFO -Message "No Chrome print preview cache in $prefPath."
                continue
            }

            $appState = $sticky | ConvertFrom-Json -ErrorAction Stop

            if (-not $appState.recentDestinations) {
                Write-CleanupLog -Level INFO -Message "No Chrome recent print destinations in $prefPath."
                continue
            }

            $before = @($appState.recentDestinations).Count
            $appState.recentDestinations = @(
                $appState.recentDestinations | Where-Object {
                    $text = "$($_.id) $($_.displayName)"
                    -not (Test-MatchesPattern -Text $text -PatternList $Patterns)
                }
            )
            $after = @($appState.recentDestinations).Count
            $removed = $before - $after

            if ($removed -le 0) {
                Write-CleanupLog -Level INFO -Message "No matched Chrome print destinations in $prefPath."
                continue
            }

            Copy-Item -Path $prefPath -Destination "$prefPath.bak" -Force -ErrorAction Stop

            $prefs.printing.print_preview_sticky_settings.appState =
            ($appState | ConvertTo-Json -Depth 20 -Compress)

            $prefs |
            ConvertTo-Json -Depth 100 -Compress |
            Set-Content -Path $prefPath -Encoding UTF8 -ErrorAction Stop

            Write-CleanupLog -Level SUCCESS -Message "Removed $removed Chrome print destination(s): $prefPath"
        }
        catch {
            Write-CleanupLog -Level ERROR -Message "Failed to clean Chrome print cache in ${prefPath}: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# 13. Restart services
# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Restarting Services ==='

foreach ($svcName in @('Spooler', 'DeviceAssociationService')) {
    Write-CleanupLog -Level INFO -Message "Starting: $svcName"
    try {
        Start-Service -Name $svcName -ErrorAction Stop
        Write-CleanupLog -Level SUCCESS -Message "Started: $svcName"
    }
    catch {
        Write-CleanupLog -Level ERROR -Message "Could not start ${svcName}: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
Write-Host -ForegroundColor DarkCyan '=== Complete ==='
Write-CleanupLog -Level SUCCESS -Message 'Cleanup complete. Reboot before retesting Add Device / printer discovery.'
