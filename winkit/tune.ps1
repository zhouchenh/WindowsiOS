# Windows-side tuning for the emulated VM: background services, widgets and inbox apps.
# (Windows Security settings are left alone: change those in the Windows Security app.)
# Run elevated:  irm http://10.0.2.4/tune.ps1 | iex
$ErrorActionPreference = 'SilentlyContinue'
$log = New-Object System.Collections.Generic.List[string]
function L($s) { $log.Add([string]$s) }
function Send { $p = "$env:TEMP\tune.txt"; $log | Out-File -Encoding ascii $p; try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri 'http://10.0.2.4/tune.txt' -InFile $p | Out-Null } catch {} }
function Reg($path, $name, $value, $type = 'DWord') {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name $name -Value $value -Type $type -ErrorAction SilentlyContinue
}
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')
L "tune start $(Get-Date -Format s) admin=$admin"
Send
if (-not $admin) { L 'not elevated: stopping'; Send; return }

Write-Host '  services...'
# --- background services
foreach ($s in 'WSearch', 'SysMain', 'DiagTrack', 'dmwappushservice', 'MapsBroker', 'WerSvc', 'edgeupdate', 'edgeupdatem',
               'MicrosoftEdgeElevationService', 'RetailDemo', 'lfsvc', 'WpnService', 'PcaSvc', 'DPS', 'wisvc', 'XblAuthManager',
               'XblGameSave', 'XboxNetApiSvc', 'XboxGipSvc', 'PhoneSvc', 'Fax', 'TrkWks') {
    $svc = Get-Service $s
    if ($svc) {
        Stop-Service $s -Force
        Set-Service $s -StartupType Disabled
        L ("service {0}: {1}" -f $s, (Get-Service $s).StartType)
    }
}
# Windows Update / Store / Delivery Optimization: no automatic downloads or installs
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 2
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 99
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1
Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat' 'DisableInventory' 1
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2

Write-Host '  scheduled tasks...'
# --- scheduled tasks that burn CPU and disk
$n = 0
foreach ($t in 'ScheduledDefrag', 'WinSAT', 'Microsoft Compatibility Appraiser', 'Microsoft Compatibility Appraiser Exp', 'ProgramDataUpdater',
               'Consolidator', 'UsbCeip', 'Microsoft-Windows-DiskDiagnosticDataCollector', 'QueueReporting', 'MapsToastTask', 'MapsUpdateTask',
               'StartComponentCleanup', 'Scheduled Start', 'XblGameSaveTask', 'FamilySafetyMonitor', 'FamilySafetyRefreshTask',
               'MicrosoftEdgeUpdateTaskMachineCore', 'MicrosoftEdgeUpdateTaskMachineUA', 'SpeechModelDownloadTask', 'StartupAppTask',
               'PcaPatchDbTask', 'Proxy', 'RecommendedTroubleshootingScanner', 'Schedule Scan', 'Schedule Maintenance Work', 'MareBackup') {
    Get-ScheduledTask -TaskName "$t*" -ErrorAction SilentlyContinue | ForEach-Object {
        # some are owned by the system and refuse (Access is denied): skip those quietly
        try { Disable-ScheduledTask -InputObject $_ -ErrorAction Stop | Out-Null; $n++ } catch {}
    }
}
L "scheduled tasks disabled: $n"

Write-Host '  removing widgets and inbox apps (the slow part, a few minutes)...'
# --- widgets, Copilot and inbox apps
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0
Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0
Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
$apps = 'MicrosoftWindows.Client.WebExperience', 'Microsoft.WidgetsPlatformRuntime', 'Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider',
        'Microsoft.YourPhone', 'MicrosoftWindows.CrossDevice', 'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch',
        'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.Xbox.TCUI',
        'MicrosoftTeams', 'MSTeams', 'Microsoft.OutlookForWindows', 'Microsoft.Todos', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo',
        'Microsoft.WindowsFeedbackHub', 'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop',
        'Microsoft.Windows.DevHome', 'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.549981C3F5F10',
        'Microsoft.WindowsMaps', 'Microsoft.MicrosoftStickyNotes', 'Microsoft.WindowsSoundRecorder', 'Microsoft.WindowsAlarms',
        'microsoft.windowscommunicationsapps', 'Microsoft.MixedReality.Portal', 'Microsoft.Microsoft3DViewer', 'MicrosoftCorporationII.QuickAssist'
$removed = @()
foreach ($a in $apps) {
    $pk = Get-AppxPackage -AllUsers -Name $a
    if ($pk) { $pk | Remove-AppxPackage -AllUsers; $removed += $a }
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -eq $a | Remove-AppxProvisionedPackage -Online | Out-Null
}
L ("apps removed: " + ($removed -join ', '))
$one = "$env:SystemRoot\System32\OneDriveSetup.exe"
if (Test-Path $one) { Start-Process $one '/uninstall' -Wait; L 'onedrive: uninstall run' }
Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1

Write-Host '  shell and power settings...'
# --- shell: no startup delay, no suggested content (transparency and animations stay: the GPU draws them)
Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1

# --- power and file system
powercfg -setactive SCHEME_MIN | Out-Null
powercfg -h off | Out-Null
powercfg -setacvalueindex scheme_current sub_processor CPMINCORES 100 | Out-Null
powercfg -setdcvalueindex scheme_current sub_processor CPMINCORES 100 | Out-Null
powercfg -setactive scheme_current | Out-Null
fsutil behavior set disablelastaccess 1 | Out-Null
fsutil 8dot3name set 1 | Out-Null
L ("power plan: " + ((powercfg -getactivescheme) -replace '\s+', ' '))

Start-Sleep 3
L ("processes now: " + (Get-Process).Count + ", services running: " + (Get-Service | Where-Object Status -eq 'Running').Count)
L 'done'
Send
