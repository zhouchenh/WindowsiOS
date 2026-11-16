# Removes WinIOS Browser (the sign-in bridge set up by oauth_setup.ps1) again: the program in
# C:\Program Files\WinIOS, its browser registration and its firewall rule. Links open in Edge again.
# Run elevated:  powershell -ExecutionPolicy Bypass -File uninstall_oauth.ps1
$ErrorActionPreference = 'Continue'
$name = 'WinIOSBrowser'
$progId = 'WinIOSHTML'
$pf = $env:ProgramW6432; if (-not $pf) { $pf = $env:ProgramFiles }
$dir = Join-Path $pf 'WinIOS'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'Run this as administrator.' -ForegroundColor Yellow; return }

$choice = ''
try { $choice = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop).ProgId } catch {}

Get-Process -Name 'WinIOSBrowser' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

$hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
foreach ($sub in "SOFTWARE\Clients\StartMenuInternet\$name", "SOFTWARE\Classes\$progId") {
    try { $hklm.DeleteSubKeyTree($sub, $false) } catch { Write-Host "  could not remove HKLM\$sub : $($_.Exception.Message)" -ForegroundColor Yellow }
}
foreach ($sub in 'SOFTWARE\RegisteredApplications', 'SOFTWARE\Classes\.htm\OpenWithProgids', 'SOFTWARE\Classes\.html\OpenWithProgids') {
    $k = $hklm.OpenSubKey($sub, $true)
    if ($k) {
        $v = $name; if ($sub -like '*OpenWithProgids') { $v = $progId }
        try { $k.DeleteValue($v, $false) } catch {} finally { $k.Close() }
    }
}
if (-not ('WinKit.ShellNotify' -as [type])) {
    Add-Type -Namespace WinKit -Name ShellNotify -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);'
}
[WinKit.ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)  # SHCNE_ASSOCCHANGED

Remove-NetFirewallRule -Name 'WinIOSBrowser-Relay' -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'WinIOS Browser removed.'
if ($choice -eq $progId) {
    Write-Host 'It was the default browser: Windows goes back to Microsoft Edge (it may ask once which app to use).'
    Write-Host 'Settings > Apps > Default apps opens now if you want to check.'
    try { Start-Process 'ms-settings:defaultapps' } catch {}
}
