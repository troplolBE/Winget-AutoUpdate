<# LOAD FUNCTIONS #>

#Get the Working Dir
$Script:WorkingDir = $PSScriptRoot
#Get Functions
Get-ChildItem "$WorkingDir\functions" | ForEach-Object { . $_.FullName }


<# MAIN #>

#Config console output encoding
$null = cmd /c ''
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

#Check if running account is system or interactive logon
$Script:IsSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

#Log initialisation
$LogFile = "$WorkingDir\logs\updates.log"

if ($IsSystem) {
    #Check if any connected user when running as system
    $explorerprocesses = @(Get-CimInstance -Query "SELECT * FROM Win32_Process WHERE Name='explorer.exe'" -ErrorAction SilentlyContinue)
    #Check if ServiceUI exists
    $ServiceUI = Test-Path "$WorkingDir\ServiceUI.exe"
    If ($explorerprocesses.Count -gt 0 -and $ServiceUI) {
        #User connected, Check for current session ID (O = system)
        $SessionID = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        if ($SessionID -eq 0) {
            #Rerun WAU in system context with ServiceUI
            & $WorkingDir\ServiceUI.exe -process:explorer.exe $env:windir\System32\wscript.exe \`"$WorkingDir\Invisible.vbs\`" \`"powershell.exe -NoProfile -ExecutionPolicy Bypass -File \`"\`"$WorkingDir\winget-upgrade.ps1\`"\`"\`"
            Exit 0
        }
        else {
            Write-ToLog -LogMsg "CHECK FOR APP UPDATES (System context with ServiceUI)" -IsHeader
        }
    }
    else {
        Write-ToLog -LogMsg "CHECK FOR APP UPDATES (System context)" -IsHeader
    }
}
else {
    Write-ToLog -LogMsg "CHECK FOR APP UPDATES (User context)" -IsHeader
}

#Get settings and Domain/Local Policies (GPO) if activated.
$Script:WAUConfig = Get-WAUConfig
if ($($WAUConfig.WAU_ActivateGPOManagement -eq 1)) {
    Write-ToLog "WAU Policies management Enabled."
}

#Log running context and more...
if ($IsSystem) {

    # Maximum number of log files to keep. Default is 3. Setting MaxLogFiles to 0 will keep all log files.
    $MaxLogFiles = $WAUConfig.WAU_MaxLogFiles
    if ($null -eq $MaxLogFiles) {
        [int32] $MaxLogFiles = 3
    }
    else {
        [int32] $MaxLogFiles = $MaxLogFiles
    }

    # Maximum size of log file.
    $MaxLogSize = $WAUConfig.WAU_MaxLogSize
    if (!$MaxLogSize) {
        [int64] $MaxLogSize = 1048576 # in bytes, default is 1048576 = 1 MB
    }
    else {
        [int64] $MaxLogSize = $MaxLogSize
    }

    #LogRotation if System
    $LogRotate = Invoke-LogRotation $LogFile $MaxLogFiles $MaxLogSize
    if ($LogRotate -eq $False) {
        Write-ToLog "An Exception occured during Log Rotation..."
    }

    #Run post update actions if necessary if run as System
    if (!($WAUConfig.WAU_PostUpdateActions -eq 0)) {
        Invoke-PostUpdateActions
    }
    #Run Scope Machine funtion if run as System
    $SettingsPath = "$Env:windir\system32\config\systemprofile\AppData\Local\Microsoft\WinGet\Settings\defaultState\settings.json"
    Add-ScopeMachine $SettingsPath
}

#Get Notif Locale function
$LocaleDisplayName = Get-NotifLocale
Write-ToLog "Notification Level: $($WAUConfig.WAU_NotificationLevel). Notification Language: $LocaleDisplayName" "Cyan"

#Check network connectivity
if (Test-Network) {
    #Check if Winget is installed and get Winget cmd
    $TestWinget = Get-WingetCmd

    if ($TestWinget) {
        #Get Current Version
        $WAUCurrentVersion = $WAUConfig.DisplayVersion
        Write-ToLog "WAU current version: $WAUCurrentVersion"
        if ($IsSystem) {
            #Check if WAU update feature is enabled or not if run as System
            $WAUDisableAutoUpdate = $WAUConfig.WAU_DisableAutoUpdate
            #If yes then check WAU update if run as System
            if ($WAUDisableAutoUpdate -eq 1) {
                Write-ToLog "WAU AutoUpdate is Disabled." "Gray"
            }
            else {
                Write-ToLog "WAU AutoUpdate is Enabled." "Green"
                #Get Available Version
                $Script:WAUAvailableVersion = Get-WAUAvailableVersion
                #Compare
                if ([version]$WAUAvailableVersion.Replace("-", ".") -ne [version]$WAUCurrentVersion.Replace("-", ".")) {
                    #If new version is available, update it
                    Write-ToLog "WAU Available version: $WAUAvailableVersion" "Yellow"
                    Update-WAU
                }
                else {
                    Write-ToLog "WAU is up to date." "Green"
                }
            }

            #Delete previous list_/winget_error (if they exist) if run as System
            if (Test-Path "$WorkingDir\logs\error.txt") {
                Remove-Item "$WorkingDir\logs\error.txt" -Force
            }

            #Get External ListPath if run as System
            if ($WAUConfig.WAU_ListPath) {
                $ListPathClean = $($WAUConfig.WAU_ListPath.TrimEnd(" ", "\", "/"))
                Write-ToLog "WAU uses External Lists from: $ListPathClean"
                if ($ListPathClean -ne "GPO") {
                    $NewList = Test-ListPath $ListPathClean $WAUConfig.WAU_UseWhiteList $WAUConfig.InstallLocation.TrimEnd(" ", "\")
                    if ($ReachNoPath) {
                        Write-ToLog "Couldn't reach/find/compare/copy from $ListPathClean..." "Red"
                        if ($ListPathClean -notlike "http*") {
                            if (Test-Path -Path "$ListPathClean" -PathType Leaf) {
                                Write-ToLog "PATH must end with a Directory, not a File..." "Red"
                            }
                        }
                        else {
                            if ($ListPathClean -match "_apps.txt") {
                                Write-ToLog "PATH must end with a Directory, not a File..." "Red"
                            }
                        }
                        $Script:ReachNoPath = $False
                    }
                    if ($NewList) {
                        Write-ToLog "Newer List downloaded/copied to local path: $($WAUConfig.InstallLocation.TrimEnd(" ", "\"))" "Yellow"
                    }
                    else {
                        if ($WAUConfig.WAU_UseWhiteList -and (Test-Path "$WorkingDir\included_apps.txt")) {
                            Write-ToLog "List (white) is up to date." "Green"
                        }
                        elseif (!$WAUConfig.WAU_UseWhiteList -and (Test-Path "$WorkingDir\excluded_apps.txt")) {
                            Write-ToLog "List (black) is up to date." "Green"
                        }
                        else {
                            Write-ToLog "Critical: White/Black List doesn't exist, exiting..." "Red"
                            New-Item "$WorkingDir\logs\error.txt" -Value "White/Black List doesn't exist" -Force
                            Exit 1
                        }
                    }
                }
            }

            #Get External ModsPath if run as System
            if ($WAUConfig.WAU_ModsPath) {
                $ModsPathClean = $($WAUConfig.WAU_ModsPath.TrimEnd(" ", "\", "/"))
                Write-ToLog "WAU uses External Mods from: $ModsPathClean"
                if ($WAUConfig.WAU_AzureBlobSASURL) {
                    $NewMods, $DeletedMods = Test-ModsPath $ModsPathClean $WAUConfig.InstallLocation.TrimEnd(" ", "\") $WAUConfig.WAU_AzureBlobSASURL.TrimEnd(" ")
                }
                else {
                    $NewMods, $DeletedMods = Test-ModsPath $ModsPathClean $WAUConfig.InstallLocation.TrimEnd(" ", "\")
                }
                if ($ReachNoPath) {
                    Write-ToLog "Couldn't reach/find/compare/copy from $ModsPathClean..." "Red"
                    $Script:ReachNoPath = $False
                }
                if ($NewMods -gt 0) {
                    Write-ToLog "$NewMods newer Mods downloaded/copied to local path: $($WAUConfig.InstallLocation.TrimEnd(" ", "\"))\mods" "Yellow"
                }
                else {
                    if (Test-Path "$WorkingDir\mods\*.ps1") {
                        Write-ToLog "Mods are up to date." "Green"
                    }
                    else {
                        Write-ToLog "No Mods are implemented..." "Yellow"
                    }
                }
                if ($DeletedMods -gt 0) {
                    Write-ToLog "$DeletedMods Mods deleted (not externally managed) from local path: $($WAUConfig.InstallLocation.TrimEnd(" ", "\"))\mods" "Red"
                }
            }

            #Test if _WAU-mods.ps1 exist: Mods for WAU (if Network is active/any Winget is installed/running as SYSTEM)
            $Mods = "$WorkingDir\mods"
            if (Test-Path "$Mods\_WAU-mods.ps1") {
                Write-ToLog "Running Mods for WAU..." "Yellow"
                & "$Mods\_WAU-mods.ps1"
                $ModsExitCode = $LASTEXITCODE
                #If _WAU-mods.ps1 has ExitCode 1 - Re-run WAU
                if ($ModsExitCode -eq 1) {
                    Write-ToLog "Re-run WAU"
                    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$WorkingDir\winget-upgrade.ps1`""
                    Exit
                }
            }

        }

        if ($($WAUConfig.WAU_ListPath) -eq "GPO") {
            $Script:GPOList = $True
        }

        #Get White or Black list
        if ($WAUConfig.WAU_UseWhiteList -eq 1) {
            Write-ToLog "WAU uses White List config"
            $toUpdate = Get-IncludedApps
            $UseWhiteList = $true
        }
        else {
            Write-ToLog "WAU uses Black List config"
            $toSkip = Get-ExcludedApps
        }

        #Fix and count the array if GPO List as ERROR handling!
        if ($GPOList) {
            if ($UseWhiteList) {
                $WhiteList = $toUpdate.GetUpperBound(0)
                if ($null -eq $WhiteList) {
                    Write-ToLog "Critical: Whitelist doesn't exist in GPO, exiting..." "Red"
                    New-Item "$WorkingDir\logs\error.txt" -Value "Whitelist doesn't exist in GPO" -Force
                    Exit 1
                }
                $toUpdate = $toUpdate.Data
            }
            else {
                $BlackList = $toSkip.GetUpperBound(0)
                if ($null -eq $BlackList) {
                    Write-ToLog "Critical: Blacklist doesn't exist in GPO, exiting..." "Red"
                    New-Item "$WorkingDir\logs\error.txt" -Value "Blacklist doesn't exist in GPO" -Force
                    Exit 1
                }
                $toSkip = $toSkip.Data
            }
        }

        #Get outdated Winget packages
        Write-ToLog "Checking application updates on Winget Repository..." "yellow"
        $outdated = Get-WingetOutdatedApps

        #If something unusual happened
        if ($outdated -like "An unusual*") {
            Write-ToLog "$outdated" "cyan"
            $outdated = $False
        }

        #Run only if $outdated is populated!
        if ($outdated) {
            #Log list of app to update
            foreach ($app in $outdated) {
                #List available updates
                $Log = "-> Available update : $($app.Name). Current version : $($app.Version). Available version : $($app.AvailableVersion)."
                $Log | Write-host
                $Log | out-file -filepath $LogFile -Append
            }

            #Count good update installations
            $Script:InstallOK = 0

            #Trick under user context when -BypassListForUsers is used
            if ($IsSystem -eq $false -and $WAUConfig.WAU_BypassListForUsers -eq 1) {
                Write-ToLog "Bypass system list in user context is Enabled."
                $UseWhiteList = $false
                $toSkip = $null
            }

            #If White List
            if ($UseWhiteList) {
                #For each app, notify and update
                foreach ($app in $outdated) {
                    if (($toUpdate -contains $app.Id) -and $($app.Version) -ne "Unknown") {
                        Update-App $app
                    }
                    #if current app version is unknown
                    elseif ($($app.Version) -eq "Unknown") {
                        Write-ToLog "$($app.Name) : Skipped upgrade because current version is 'Unknown'" "Gray"
                    }
                    #if app is in "excluded list"
                    else {
                        Write-ToLog "$($app.Name) : Skipped upgrade because it is not in the included app list" "Gray"
                    }
                }
            }
            #If Black List or default
            else {
                #For each app, notify and update
                foreach ($app in $outdated) {
                    if (-not ($toSkip -contains $app.Id) -and $($app.Version) -ne "Unknown") {
                        Update-App $app
                    }
                    #if current app version is unknown
                    elseif ($($app.Version) -eq "Unknown") {
                        Write-ToLog "$($app.Name) : Skipped upgrade because current version is 'Unknown'" "Gray"
                    }
                    #if app is in "excluded list"
                    else {
                        Write-ToLog "$($app.Name) : Skipped upgrade because it is in the excluded app list" "Gray"
                    }
                }
            }

            if ($InstallOK -gt 0) {
                Write-ToLog "$InstallOK apps updated ! No more update." "Green"
            }
        }

        if ($InstallOK -eq 0 -or !$InstallOK) {
            Write-ToLog "No new update." "Green"
        }

        #Check if user context is activated during system run
        if ($IsSystem) {

            #Adds SymLink if Intune managed
            $IntuneLogPath = "${env:ProgramData}\Microsoft\IntuneManagementExtension\Logs"
            if ((Test-Path "$IntuneLogPath") -and !(Test-Path "$IntuneLogPath\WAU-updates.log")) {
                Write-ToLog "Creating SymLink for log file (WAU-updates) in Intune Management Extension log folder" "Yellow"
                New-Item -Path "$IntuneLogPath\WAU-updates.log" -ItemType SymbolicLink -Value $LogFile -Force -ErrorAction SilentlyContinue | Out-Null
            }

            #Run WAU in user context if feature is activated
            if ($WAUConfig.WAU_UserContext -eq 1) {

                #Create User context task if not existing
                $UserContextTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate-UserContext' -ErrorAction SilentlyContinue
                if (!$UserContextTask) {
                    #Create the scheduled task in User context
                    $taskAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$($WAUConfig.InstallLocation)\Invisible.vbs`" `"powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"`"`"$($WAUConfig.InstallLocation)\winget-upgrade.ps1`"`""
                    $taskUserPrincipal = New-ScheduledTaskPrincipal -GroupId S-1-5-11
                    $taskSettings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 03:00:00
                    $task = New-ScheduledTask -Action $taskAction -Principal $taskUserPrincipal -Settings $taskSettings
                    Register-ScheduledTask -TaskName 'Winget-AutoUpdate-UserContext' -TaskPath 'WAU' -InputObject $task -Force | Out-Null
                    Write-ToLog "-> User Context task created."

                    #Load it
                    $UserContextTask = Get-ScheduledTask -TaskName 'Winget-AutoUpdate-UserContext' -ErrorAction SilentlyContinue
                }

                $explorerprocesses = @(Get-CimInstance -Query "SELECT * FROM Win32_Process WHERE Name='explorer.exe'" -ErrorAction SilentlyContinue)
                If ($explorerprocesses.Count -eq 0) {
                    Write-ToLog "No explorer process found / Nobody interactively logged on..."
                }
                Else {
                    #Get Winget system apps to excape them befor running user context
                    Write-ToLog "User logged on, get a list of installed Winget apps in System context..."
                    Get-WingetSystemApps

                    #Run user context scheduled task
                    Write-ToLog "Starting WAU in User context..."
                    $null = $UserContextTask | Start-ScheduledTask -ErrorAction SilentlyContinue
                    Exit 0
                }
            }
        }
    }
    else {
        Write-ToLog "Critical: Winget not installed or detected, exiting..." "red"
        New-Item "$WorkingDir\logs\error.txt" -Value "Winget not installed or detected" -Force
        Write-ToLog "End of process!" "Cyan"
        Exit 1
    }
}

#End
Write-ToLog "End of process!" "Cyan"
Start-Sleep 3
