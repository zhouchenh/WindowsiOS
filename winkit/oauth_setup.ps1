# WinKit: sign-in links from Windows open in Safari on the iPhone (the app's OAuth bridge).
# Installs WinIOSBrowser.exe (the Windows half of the bridge, see docs/oauth-bridge.md) in
# C:\Program Files\WinIOS, registers it as a browser named "WinIOS Browser" (ProgID WinIOSHTML for
# http, https, .htm and .html), lets its sign-in callback relay through the firewall, and opens
# Settings so that you can make it the default browser: Windows 11 does not let a program do that.
# Safe to run again. Needs administrator rights: run it through SAFARI-SIGNIN.bat (or START.bat).
#   powershell -ExecutionPolicy Bypass -File oauth_setup.ps1 [-NoSettings]
# uninstall_oauth.ps1 removes it again.
param([switch]$NoSettings)
$ErrorActionPreference = 'Stop'
$name = 'WinIOSBrowser'          # Clients\StartMenuInternet and RegisteredApplications name
$progId = 'WinIOSHTML'
$display = 'WinIOS Browser'
$pf = $env:ProgramW6432; if (-not $pf) { $pf = $env:ProgramFiles }
$dir = Join-Path $pf 'WinIOS'
$exe = Join-Path $dir 'WinIOSBrowser.exe'
$src = Join-Path $PSScriptRoot 'WinIOSBrowser.exe'
$fwRule = 'WinIOSBrowser-Relay'

function HttpsChoice {
    try { (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop).ProgId }
    catch { '' }
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host '  Administrator rights are needed: double-click SAFARI-SIGNIN.bat instead.' -ForegroundColor Yellow
    return
}
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "  WinIOSBrowser.exe is not next to this script ($PSScriptRoot): use a newer WinKit disk." -ForegroundColor Yellow
    return
}

try {
    # The program. A relay left running from an earlier sign-in would keep the old file in use.
    Get-Process -Name 'WinIOSBrowser' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ((Resolve-Path -LiteralPath $src).Path -ne $exe) { Copy-Item -LiteralPath $src -Destination $exe -Force }

    # The browser registration (64-bit registry view, whatever PowerShell this is).
    $hklm = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    function SetValues([string]$sub, [hashtable]$values) {
        $k = $hklm.CreateSubKey($sub)
        try { foreach ($n in $values.Keys) { $k.SetValue($n, $values[$n]) } } finally { $k.Close() }
    }
    $icon = '"' + $exe + '",0'
    $desc = 'Opens links from Windows in Safari on the iPhone (sign-in bridge of the app); Microsoft Edge otherwise.'
    $client = "SOFTWARE\Clients\StartMenuInternet\$name"
    SetValues $client @{ '' = $display }
    SetValues "$client\Capabilities" @{ 'ApplicationName' = $display; 'ApplicationDescription' = $desc; 'ApplicationIcon' = $icon }
    SetValues "$client\Capabilities\FileAssociations" @{ '.htm' = $progId; '.html' = $progId }
    SetValues "$client\Capabilities\URLAssociations" @{ 'http' = $progId; 'https' = $progId }
    SetValues "$client\Capabilities\StartMenu" @{ 'StartMenuInternet' = $name }
    SetValues "$client\DefaultIcon" @{ '' = $icon }
    SetValues "$client\shell\open\command" @{ '' = ('"' + $exe + '"') }
    SetValues 'SOFTWARE\RegisteredApplications' @{ $name = "Software\Clients\StartMenuInternet\$name\Capabilities" }
    $cls = "SOFTWARE\Classes\$progId"
    SetValues $cls @{ '' = 'WinIOS Browser HTML Document' }
    SetValues "$cls\Application" @{ 'ApplicationName' = $display; 'ApplicationDescription' = $desc; 'ApplicationIcon' = $icon }
    SetValues "$cls\DefaultIcon" @{ '' = $icon }
    SetValues "$cls\shell\open\command" @{ '' = ('"' + $exe + '" "%1"') }
    SetValues 'SOFTWARE\Classes\.htm\OpenWithProgids' @{ $progId = '' }
    SetValues 'SOFTWARE\Classes\.html\OpenWithProgids' @{ $progId = '' }
    if (-not ('WinKit.ShellNotify' -as [type])) {
        Add-Type -Namespace WinKit -Name ShellNotify -MemberDefinition '[DllImport("shell32.dll")] public static extern void SHChangeNotify(int e, uint f, IntPtr a, IntPtr b);'
    }
    [WinKit.ShellNotify]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)  # SHCNE_ASSOCCHANGED
    Write-Host "  installed: $exe"
} catch {
    Write-Host "  Could not install WinIOS Browser: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# The sign-in callback: WinIOSBrowser.exe listens on 10.0.2.15:<port> for the browser on the iPhone
# (forwarded by the app) and passes it on to the program waiting on localhost:<port>.
try {
    Remove-NetFirewallRule -Name $fwRule -ErrorAction SilentlyContinue
    $rule = @{ Name = $fwRule; DisplayName = 'WinIOS Browser (sign-in callback relay)'; Direction = 'Inbound'; Action = 'Allow';
               Protocol = 'TCP'; Program = $exe; RemoteAddress = 'LocalSubnet'; Profile = 'Any' }
    New-NetFirewallRule @rule | Out-Null
    Write-Host '  firewall: sign-in callbacks from the app allowed'
} catch {
    Write-Host "  firewall rule not added ($($_.Exception.Message)): Windows may ask once to allow WinIOS Browser" -ForegroundColor Yellow
}

if ((HttpsChoice) -eq $progId) {
    Write-Host '  WinIOS Browser is already the default browser.' -ForegroundColor Green
} elseif ($NoSettings) {
    Write-Host '  Not the default browser yet: Settings > Apps > Default apps > WinIOS Browser > Set default.'
} else {
    Write-Host ''
    Write-Host '  Windows lets only you choose the default browser. Settings opens now:' -ForegroundColor Yellow
    Write-Host '    on the "WinIOS Browser" page click "Set default" at the top' -ForegroundColor Yellow
    Write-Host '    (if there is no such button, set .htm, .html, HTTP and HTTPS to WinIOS Browser one by one).' -ForegroundColor Yellow
    try { Start-Process "ms-settings:defaultapps?registeredAppMachine=$name" }
    catch { try { Start-Process 'ms-settings:defaultapps' } catch {} }
    Read-Host '  Press Enter here when done (or to skip)' | Out-Null
    if ((HttpsChoice) -eq $progId) { Write-Host '  WinIOS Browser is the default browser now.' -ForegroundColor Green }
    else { Write-Host '  Not chosen: links keep opening in Edge. Run SAFARI-SIGNIN.bat any time to choose it.' }
}
Write-Host '  In the app, Settings > "Open sign-in links from Windows in Safari" switches between Safari and Edge.'
