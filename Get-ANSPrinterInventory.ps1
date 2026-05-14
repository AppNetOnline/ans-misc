Function Get-ANSPrinterInventory {
    <#
    .SYNOPSIS
        Captures a complete printer inventory for the local workstation.

    .DESCRIPTION
        Captures machine printers, loaded-user printer connections, default printers,
        print server origin, port classification, and stale print server references.
        Optionally loads offline user hives (NTUSER.DAT) so the audit captures
        printer connections for users who are not currently signed in. This is
        important when running the function under SYSTEM via RMM, since only the
        active console user's hive is loaded by default.

    .PARAMETER NetworkSharePath
        Optional UNC path used to copy the generated JSON and CSV reports.

    .PARAMETER OldPrintServer
        Optional old print server name used to flag stale printer connections.

    .PARAMETER AuditDirectory
        Local directory used to store the inventory output.

    .PARAMETER IncludeOfflineUsers
        When supplied, loads each local user profile's NTUSER.DAT that is not
        currently loaded, scans \Printers\Connections, then unloads the hive.
        Required for complete coverage when running as SYSTEM via RMM.

    .EXAMPLE
        Get-ANSPrinterInventory;

    .EXAMPLE
        Get-ANSPrinterInventory `
            -NetworkSharePath '\\DC1\Logs\PrinterInventory' `
            -OldPrintServer 'FS1' `
            -IncludeOfflineUsers;

    .NOTES
        Author:  ANS / AppNetOnline
        Updated: 2026-05-13
    #>

    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $True)]
        [String]
        $NetworkSharePath,

        [Parameter(Mandatory = $True)]
        [String]
        $OldPrintServer,

        [Parameter(Mandatory = $False)]
        [String]
        $AuditDirectory = 'C:\ANS\PrinterAudit',

        [Parameter(Mandatory = $False)]
        [Switch]
        $IncludeOfflineUsers
    );

    Begin {
        Set-StrictMode -Version Latest;
        $ErrorActionPreference = 'Stop';

        $HostName = $env:COMPUTERNAME;
        New-Item -ItemType Directory -Path $AuditDirectory -Force | Out-Null;

        $LogPath = Join-Path -Path $AuditDirectory -ChildPath "$HostName-printer-inventory.log";
        $JsonPath = Join-Path -Path $AuditDirectory -ChildPath "$HostName-printer-inventory.json";
        $CsvPath = Join-Path -Path $AuditDirectory -ChildPath "$HostName-printer-inventory.csv";

        Function Write-ANSLog {
            Param (
                [Parameter(Mandatory = $True)]
                [String]$Message,

                [Parameter(Mandatory = $False)]
                [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')]
                [String]$Level = 'INFO'
            );

            $Entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message";
            Add-Content -Path $LogPath -Value $Entry;

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
            };
        };

        Function Get-ANSPortClassification {
            Param (
                [Parameter(Mandatory = $False)]
                [AllowNull()]
                [Object]$Port
            );

            If ($Null -eq $Port) {
                Return [PSCustomObject]@{
                    Type   = 'Unknown';
                    Detail = $Null;
                };
            };

            $Name = $Port.Name;

            If ($Name -match '^WSD-') {
                Return [PSCustomObject]@{
                    Type   = 'WSD';
                    Detail = $Name;
                };
            };

            If ($Name -like '\\*') {
                Return [PSCustomObject]@{
                    Type   = 'Server';
                    Detail = $Name;
                };
            };

            If (($Port.Description -match 'Standard TCP/IP Port') -or ($Name -match '^IP_')) {
                $EscapedName = $Name.Replace("'", "''");

                $TcpPort = Get-CimInstance `
                    -ClassName Win32_TCPIPPrinterPort `
                    -Filter "Name='$EscapedName'" `
                    -ErrorAction SilentlyContinue;

                If ($TcpPort) {
                    $Protocol = Switch ($TcpPort.Protocol) {
                        1 {
                            'RAW';
                        }
                        2 {
                            'LPR';
                        }
                        Default {
                            'RAW';
                        }
                    };

                    Return [PSCustomObject]@{
                        Type   = 'TCPIP';
                        Detail = "$($TcpPort.HostAddress):$($TcpPort.PortNumber) ($Protocol)";
                    };
                };

                Return [PSCustomObject]@{
                    Type   = 'TCPIP';
                    Detail = $Name;
                };
            };

            If ($Name -match '^LPT\d') {
                Return [PSCustomObject]@{
                    Type   = 'LPT';
                    Detail = $Name;
                };
            };

            If ($Name -match '^COM\d') {
                Return [PSCustomObject]@{
                    Type   = 'COM';
                    Detail = $Name;
                };
            };

            If ($Name -match '^USB') {
                Return [PSCustomObject]@{
                    Type   = 'USB';
                    Detail = $Name;
                };
            };

            If ($Name -match '^FILE') {
                Return [PSCustomObject]@{
                    Type   = 'FILE';
                    Detail = $Name;
                };
            };

            If ($Name -match 'nul:') {
                Return [PSCustomObject]@{
                    Type   = 'NUL';
                    Detail = $Name;
                };
            };

            Return [PSCustomObject]@{
                Type   = 'Other';
                Detail = $Name;
            };
        };

        Function Get-ANSServerFromPrinterName {
            Param (
                [Parameter(Mandatory = $False)]
                [AllowNull()]
                [String]$PrinterName
            );

            If ($PrinterName -match '^\\\\([^\\]+)\\') {
                Return $Matches[1];
            };

            Return $Null;
        };

        Function Test-ANSOldPrintServer {
            Param (
                [Parameter(Mandatory = $False)]
                [AllowNull()]
                [String]$ServerHost,

                [Parameter(Mandatory = $False)]
                [AllowNull()]
                [String]$OldServer
            );

            If ([String]::IsNullOrWhiteSpace($OldServer) -or [String]::IsNullOrWhiteSpace($ServerHost)) {
                Return $False;
            };

            Return (($ServerHost -ieq $OldServer) -or ($ServerHost -ilike "$OldServer.*"));
        };

        Function Get-ANSHiveConnections {
            <#
            .SYNOPSIS
                Enumerates Printers\Connections under HKEY_USERS\<SubKey> using
                the .NET registry API directly so handles are released
                deterministically. This is critical for offline hive scans
                where reg.exe unload will fail if PowerShell still holds any
                handles. Also reads the per-user default printer. Returns the
                array of connection PSCustomObjects; default printer name is
                surfaced via $Script:LastHiveDefault.
            #>
            Param (
                [Parameter(Mandatory = $True)]
                [String]$SubKey,

                [Parameter(Mandatory = $True)]
                [String]$Sid,

                [Parameter(Mandatory = $True)]
                [String]$UserTag,

                [Parameter(Mandatory = $False)]
                [AllowNull()]
                [String]$OldServer
            );

            $Script:LastHiveDefault = $Null;
            $Results = @();

            $HkuBase = $Null;
            $HiveRoot = $Null;
            $ConnectionsKey = $Null;
            $WindowsKey = $Null;

            Try {
                $HkuBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                    [Microsoft.Win32.RegistryHive]::Users,
                    [Microsoft.Win32.RegistryView]::Default
                );

                $HiveRoot = $HkuBase.OpenSubKey($SubKey);

                If ($Null -eq $HiveRoot) {
                    Return , $Results;
                };

                # --- Printers\Connections ---
                Try {
                    $ConnectionsKey = $HiveRoot.OpenSubKey('Printers\Connections');
                }
                Catch {
                    $ConnectionsKey = $Null;
                };

                If ($ConnectionsKey) {
                    ForEach ($Name in $ConnectionsKey.GetSubKeyNames()) {
                        $RawName = $Name -replace '^,,', '' -replace ',', '\';
                        $UncName = "\\$RawName";
                        $ServerHost = Get-ANSServerFromPrinterName -PrinterName $UncName;
                        $PointsToOldServer = Test-ANSOldPrintServer -ServerHost $ServerHost -OldServer $OldServer;

                        $DriverName = $Null;
                        $ConnSub = $Null;

                        Try {
                            $ConnSub = $ConnectionsKey.OpenSubKey($Name);

                            If ($ConnSub) {
                                $DriverName = $ConnSub.GetValue('Printer');
                            };
                        }
                        Catch {
                            # Swallow per-key errors so a single bad key doesn't kill the scan
                        }
                        Finally {
                            If ($ConnSub) {
                                $ConnSub.Close();
                                $ConnSub.Dispose();
                                $ConnSub = $Null;
                            };
                        };

                        $Results += [PSCustomObject]@{
                            Source         = 'User-Connection';
                            UserSid        = $Sid;
                            UserName       = $UserTag;
                            Name           = $UncName;
                            ShareName      = $Null;
                            DriverName     = $DriverName;
                            PortName       = $Null;
                            PortType       = 'Server';
                            PortDetail     = $UncName;
                            ServerHost     = $ServerHost;
                            IsNetwork      = $True;
                            PointsToOldSrv = $PointsToOldServer;
                            Shared         = $False;
                            Published      = $False;
                            PrinterStatus  = $Null;
                            JobCount       = $Null;
                            IsDefault      = $False;
                            DefaultForUser = $Null;
                        };

                        Write-ANSLog -Message "  User connection: $UncName";
                    };
                };

                # --- Default printer (Software\Microsoft\Windows NT\CurrentVersion\Windows\Device) ---
                Try {
                    $WindowsKey = $HiveRoot.OpenSubKey('Software\Microsoft\Windows NT\CurrentVersion\Windows');

                    If ($WindowsKey) {
                        $DeviceValue = $WindowsKey.GetValue('Device');

                        If ($DeviceValue) {
                            $Script:LastHiveDefault = ($DeviceValue -split ',')[0];
                        };
                    };
                }
                Catch {
                    # Default printer is optional, ignore failures
                };
            }
            Finally {
                If ($WindowsKey) {
                    $WindowsKey.Close();
                    $WindowsKey.Dispose();
                };

                If ($ConnectionsKey) {
                    $ConnectionsKey.Close();
                    $ConnectionsKey.Dispose();
                };

                If ($HiveRoot) {
                    $HiveRoot.Close();
                    $HiveRoot.Dispose();
                };

                If ($HkuBase) {
                    $HkuBase.Close();
                    $HkuBase.Dispose();
                };
            };

            Return , $Results;
        };

        Write-Host -ForegroundColor DarkCyan "=== ANS Printer Inventory: $HostName ===";
        Write-ANSLog -Message "Inventory started on $HostName";

        If ($OldPrintServer) {
            Write-ANSLog -Message "Flagging connections to old server: $OldPrintServer";
        };

        If ($IncludeOfflineUsers) {
            Write-ANSLog -Message 'Offline hive scanning enabled';
        };
    }

    Process {
        #region Machine Printers

        Write-Host -ForegroundColor DarkCyan "`n=== Machine-Context Printers ===";

        $MachinePrinters = @();

        Try {
            $Ports = Get-PrinterPort -ErrorAction Stop;
            $PortLookup = @{};

            ForEach ($Port in $Ports) {
                $PortLookup[$Port.Name] = $Port;
            };

            $Printers = Get-Printer -ErrorAction Stop;

            ForEach ($Printer in $Printers) {
                $Port = $Null;

                If ($PortLookup.ContainsKey($Printer.PortName)) {
                    $Port = $PortLookup[$Printer.PortName];
                };

                $Classification = Get-ANSPortClassification -Port $Port;
                $ServerHost = Get-ANSServerFromPrinterName -PrinterName $Printer.Name;
                $PointsToOldServer = Test-ANSOldPrintServer -ServerHost $ServerHost -OldServer $OldPrintServer;

                $Entry = [PSCustomObject]@{
                    Source         = 'Machine';
                    UserSid        = $Null;
                    UserName       = $Null;
                    Name           = $Printer.Name;
                    ShareName      = $Printer.ShareName;
                    DriverName     = $Printer.DriverName;
                    PortName       = $Printer.PortName;
                    PortType       = $Classification.Type;
                    PortDetail     = $Classification.Detail;
                    ServerHost     = $ServerHost;
                    IsNetwork      = (($Printer.Type -eq 'Connection') -or ($Null -ne $ServerHost));
                    PointsToOldSrv = $PointsToOldServer;
                    Shared         = $Printer.Shared;
                    Published      = $Printer.Published;
                    PrinterStatus  = $Printer.PrinterStatus;
                    JobCount       = $Printer.JobCount;
                    IsDefault      = $False;
                    DefaultForUser = $Null;
                };

                $MachinePrinters += $Entry;
                Write-ANSLog -Message "Machine printer: $($Printer.Name) [$($Classification.Type)] -> $($Classification.Detail)";
            };

            Write-ANSLog -Message "Found $($MachinePrinters.Count) machine-context printers" -Level 'SUCCESS';
        }
        Catch {
            Write-ANSLog -Message "Failed to enumerate machine printers: $($_.Exception.Message)" -Level 'ERROR';
        };

        #endregion Machine Printers

        #region User Printers - Loaded Hives

        Write-Host -ForegroundColor DarkCyan "`n=== Per-User Printer Connections (Loaded Hives) ===";

        If (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
            New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS -Scope Script | Out-Null;
        };

        $ProfileList = Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Special;
        };

        $SidToUser = @{};
        $SidToProfilePath = @{};

        ForEach ($UserProfile in $ProfileList) {
            Try {
                $UserName = (New-Object System.Security.Principal.SecurityIdentifier($UserProfile.SID)).Translate(
                    [System.Security.Principal.NTAccount]
                ).Value;

                $SidToUser[$UserProfile.SID] = $UserName;
            }
            Catch {
                $SidToUser[$UserProfile.SID] = $UserProfile.LocalPath;
            };

            $SidToProfilePath[$UserProfile.SID] = $UserProfile.LocalPath;
        };

        $UserPrinters = @();
        $UserDefaults = @{};

        $LoadedSids = Get-ChildItem 'HKU:\' -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.PSChildName -match '^S-1-5-21-') -and
            ($_.PSChildName -notmatch '_Classes$');
        };

        $LoadedSidSet = @{};

        ForEach ($SidKey in $LoadedSids) {
            $Sid = $SidKey.PSChildName;
            $LoadedSidSet[$Sid] = $True;

            If ($SidToUser.ContainsKey($Sid)) {
                $UserTag = $SidToUser[$Sid];
            }
            Else {
                $UserTag = $Sid;
            };

            Write-ANSLog -Message "Scanning loaded hive: $UserTag";

            $HiveResults = Get-ANSHiveConnections `
                -SubKey $Sid `
                -Sid $Sid `
                -UserTag $UserTag `
                -OldServer $OldPrintServer;

            $UserPrinters += $HiveResults;

            If ($Script:LastHiveDefault) {
                $UserDefaults[$Sid] = [PSCustomObject]@{
                    UserTag     = $UserTag;
                    DefaultName = $Script:LastHiveDefault;
                };

                Write-ANSLog -Message "  Default printer for $UserTag = $($Script:LastHiveDefault)";
            };
        };

        #endregion User Printers - Loaded Hives

        #region User Printers - Offline Hives

        If ($IncludeOfflineUsers) {
            Write-Host -ForegroundColor DarkCyan "`n=== Per-User Printer Connections (Offline Hives) ===";

            $OfflineProfiles = $ProfileList |
            Where-Object {
                (-not $LoadedSidSet.ContainsKey($_.SID)) -and
                ($_.LocalPath -like 'C:\Users\*') -and
                (-not [String]::IsNullOrWhiteSpace($_.LocalPath));
            };

            ForEach ($Offline in $OfflineProfiles) {
                $Sid = $Offline.SID;
                $NtUserPath = Join-Path -Path $Offline.LocalPath -ChildPath 'NTUSER.DAT';

                If (-not (Test-Path -Path $NtUserPath)) {
                    Write-ANSLog -Message "Skipping $($Offline.LocalPath): NTUSER.DAT not found" -Level 'WARN';
                    Continue;
                };

                If ($SidToUser.ContainsKey($Sid)) {
                    $UserTag = $SidToUser[$Sid];
                }
                Else {
                    $UserTag = $Offline.LocalPath;
                };

                # Pre-flight: skip hives currently in use. Win32_UserProfile.Loaded can be
                # stale; the authoritative test is whether we can open the file exclusively.
                $IsLocked = $False;
                Try {
                    $TestStream = [System.IO.File]::Open(
                        $NtUserPath,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::None
                    );
                    $TestStream.Close();
                    $TestStream.Dispose();
                }
                Catch {
                    $IsLocked = $True;
                };

                If ($IsLocked) {
                    Write-ANSLog -Message "Skipping $UserTag : NTUSER.DAT is currently in use (user signed in)" -Level 'WARN';
                    Continue;
                };

                $TempKey = 'ANSPrinterAudit_' + ($Sid -replace '[^0-9A-Za-z]', '_');
                Write-ANSLog -Message "Loading offline hive: $UserTag";

                $Loaded = $False;

                Try {
                    $LoadOutput = & reg.exe load "HKU\$TempKey" "$NtUserPath" 2>&1;

                    If ($LASTEXITCODE -ne 0) {
                        Write-ANSLog -Message "Could not load hive for $UserTag : $LoadOutput" -Level 'WARN';
                        Continue;
                    };

                    $Loaded = $True;

                    $HiveResults = Get-ANSHiveConnections `
                        -SubKey $TempKey `
                        -Sid $Sid `
                        -UserTag $UserTag `
                        -OldServer $OldPrintServer;

                    $UserPrinters += $HiveResults;

                    If ($Script:LastHiveDefault) {
                        $UserDefaults[$Sid] = [PSCustomObject]@{
                            UserTag     = $UserTag;
                            DefaultName = $Script:LastHiveDefault;
                        };

                        Write-ANSLog -Message "  Default printer for $UserTag = $($Script:LastHiveDefault)";
                    };
                }
                Catch {
                    Write-ANSLog -Message "Error scanning offline hive for $UserTag : $($_.Exception.Message)" -Level 'ERROR';
                }
                Finally {
                    If ($Loaded) {
                        # Drop in-scope references that may hold handles into the hive.
                        # PowerShell's Registry provider caches enumeration handles which
                        # GC alone won't release fast enough — explicit nulling first.
                        $HiveResults = $Null;
                        $Connection = $Null;
                        $Connections = $Null;
                        $PrinterProp = $Null;
                        $DeviceProp = $Null;

                        # Multi-pass GC. Two collections are required to reclaim
                        # objects that have finalizers (registry SafeHandles do).
                        [GC]::Collect();
                        [GC]::WaitForPendingFinalizers();
                        [GC]::Collect();
                        Start-Sleep -Milliseconds 750;

                        $UnloadSucceeded = $False;

                        For ($Attempt = 1; $Attempt -le 3; $Attempt++) {
                            # Capture both streams cleanly so stderr doesn't echo to host
                            $UnloadOutput = & reg.exe unload "HKU\$TempKey" 2>&1 |
                            Out-String;
                            $UnloadOutput = $UnloadOutput.Trim();

                            If ($LASTEXITCODE -eq 0) {
                                $UnloadSucceeded = $True;
                                Break;
                            };

                            If ($Attempt -lt 3) {
                                Write-ANSLog -Message "Unload attempt $Attempt failed for $UserTag, retrying..." -Level 'WARN';
                                [GC]::Collect();
                                [GC]::WaitForPendingFinalizers();
                                [GC]::Collect();
                                Start-Sleep -Seconds ($Attempt + 1);
                            };
                        };

                        If (-not $UnloadSucceeded) {
                            Write-ANSLog -Message "Hive unload FAILED for $UserTag after 3 attempts: $UnloadOutput" -Level 'ERROR';
                            Write-ANSLog -Message "Manual cleanup: reg.exe unload HKU\$TempKey  (or reboot to release)" -Level 'WARN';
                        };
                    };
                };
            };
        };

        #endregion User Printers - Offline Hives

        #region Default Printer Flagging

        ForEach ($Sid in $UserDefaults.Keys) {
            $DefaultEntry = $UserDefaults[$Sid];
            $DefaultName = $DefaultEntry.DefaultName;
            $UserTag = $DefaultEntry.UserTag;

            $UserPrinters |
            Where-Object {
                ($_.UserSid -eq $Sid) -and ($_.Name -eq $DefaultName);
            } |
            ForEach-Object {
                $_.IsDefault = $True;
                $_.DefaultForUser = $UserTag;
            };

            $MachinePrinters |
            Where-Object {
                $_.Name -eq $DefaultName;
            } |
            ForEach-Object {
                If (-not $_.DefaultForUser) {
                    $_.IsDefault = $True;
                    $_.DefaultForUser = $UserTag;
                }
                Else {
                    $_.DefaultForUser += ";$UserTag";
                };
            };
        };

        Write-ANSLog -Message "Found $($UserPrinters.Count) per-user printer connections" -Level 'SUCCESS';

        #endregion Default Printer Flagging

        #region Output

        $AllPrinters = @($MachinePrinters) + @($UserPrinters);

        Write-Host -ForegroundColor DarkCyan "`n=== Summary ===";

        $GroupedPrinters = $AllPrinters |
        Group-Object -Property PortType |
        Sort-Object -Property Name;

        ForEach ($Group in $GroupedPrinters) {
            Write-ANSLog -Message "  $($Group.Name): $($Group.Count)";
        };

        If ($OldPrintServer) {
            $StalePrinters = @($AllPrinters | Where-Object { $_.PointsToOldSrv; });

            If ($StalePrinters.Count -gt 0) {
                Write-ANSLog -Message "Found $($StalePrinters.Count) printer(s) still pointing at $OldPrintServer" -Level 'WARN';

                $StalePrinters |
                ForEach-Object {
                    Write-ANSLog -Message "  STALE: $($_.Name) (user: $($_.UserName))" -Level 'WARN';
                };
            }
            Else {
                Write-ANSLog -Message "No connections to $OldPrintServer detected" -Level 'SUCCESS';
            };
        };

        $Report = [PSCustomObject]@{
            Hostname       = $HostName;
            Domain         = $env:USERDOMAIN;
            CollectedUtc   = (Get-Date).ToUniversalTime().ToString('o');
            OSVersion      = [System.Environment]::OSVersion.VersionString;
            OldPrintServer = $OldPrintServer;
            ScannedOffline = [Bool]$IncludeOfflineUsers;
            PrinterCount   = $AllPrinters.Count;
            StaleCount     = If ($OldPrintServer) {
                @($AllPrinters | Where-Object { $_.PointsToOldSrv; }).Count;
            }
            Else {
                $Null;
            };
            Printers       = $AllPrinters;
        };

        Try {
            $Report |
            ConvertTo-Json -Depth 6 |
            Set-Content -Path $JsonPath -Encoding UTF8;

            Write-ANSLog -Message "Wrote JSON: $JsonPath" -Level 'SUCCESS';
        }
        Catch {
            Write-ANSLog -Message "Failed to write JSON: $($_.Exception.Message)" -Level 'ERROR';
        };

        Try {
            $AllPrinters |
            Select-Object `
            @{ Name = 'Hostname'; Expression = { $HostName; } },
            Source,
            UserName,
            Name,
            DriverName,
            PortType,
            PortDetail,
            ServerHost,
            IsNetwork,
            PointsToOldSrv,
            IsDefault,
            DefaultForUser |
            Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8;

            Write-ANSLog -Message "Wrote CSV: $CsvPath" -Level 'SUCCESS';
        }
        Catch {
            Write-ANSLog -Message "Failed to write CSV: $($_.Exception.Message)" -Level 'ERROR';
        };

        If ($NetworkSharePath) {
            Try {
                If (-not (Test-Path -Path $NetworkSharePath)) {
                    Write-ANSLog -Message "Share not reachable: $NetworkSharePath" -Level 'WARN';
                }
                Else {
                    Copy-Item -Path $JsonPath -Destination $NetworkSharePath -Force;
                    Copy-Item -Path $CsvPath -Destination $NetworkSharePath -Force;

                    Write-ANSLog -Message "Copied reports to $NetworkSharePath" -Level 'SUCCESS';
                };
            }
            Catch {
                Write-ANSLog -Message "Failed to copy to share: $($_.Exception.Message)" -Level 'ERROR';
            };
        };

        Write-Host -ForegroundColor DarkCyan "`n=== Inventory complete ===";
        Write-Host -ForegroundColor Green "[+] $($AllPrinters.Count) total printer entries captured";
        Write-Host -ForegroundColor DarkGray "[i] Reports: $AuditDirectory";

        Return $Report;

        #endregion Output
    }
};