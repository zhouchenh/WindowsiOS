# WinKit: let other devices use Remote Desktop to reach this Windows (through the app's port forwarding).
# Turns on the Remote Desktop host and opens TCP and UDP on its port (3389 unless changed) in the firewall, for
# every network profile and from any address: the app's network is private to the phone, and connections from
# the phone's Wi-Fi or VPN arrive with the client's own address. Network Level Authentication stays on.
# Only Windows Pro, Enterprise and Education can accept Remote Desktop; on Home it explains the alternatives.
# An account with a blank password cannot sign in over Remote Desktop: it says so (it never sets a password).
# Safe to run again. Needs administrator rights: run it through REMOTE-DESKTOP.bat.
#   powershell -ExecutionPolicy Bypass -File enable_rdp.ps1              turn it on
#   powershell -ExecutionPolicy Bypass -File enable_rdp.ps1 -Uninstall   undo: back to how it was, rules removed
# Then, in the app: Settings > Network > Server mode (or Port forwarding > Add a port forward > Remote Desktop).
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$ts = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
$state = 'HKLM:\SOFTWARE\AppleVM\WinKit'
$rules = 'AppleVM-RDP-TCP', 'AppleVM-RDP-UDP'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host '  Administrator rights are needed: double-click REMOTE-DESKTOP.bat instead.' -ForegroundColor Yellow
    exit 1
}

function Get-Edition {
    try { return [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID }
    catch { return '' }
}
function Get-RdpPort {
    try {
        $p = (Get-ItemProperty -LiteralPath "$ts\WinStations\RDP-Tcp" -ErrorAction Stop).PortNumber
        if ($p -gt 0 -and $p -lt 65536) { return [int]$p }
    } catch {}
    return 3389
}
function Remove-Rules {
    foreach ($r in $rules) { Remove-NetFirewallRule -Name $r -ErrorAction SilentlyContinue }
}

if ($Uninstall) {
    Remove-Rules
    $before = $null
    try { $before = (Get-ItemProperty -LiteralPath $state -ErrorAction Stop).RdpDenyBefore } catch {}
    if ($null -ne $before) {
        Set-ItemProperty -LiteralPath $ts -Name fDenyTSConnections -Value ([int]$before)
        Remove-ItemProperty -LiteralPath $state -Name RdpDenyBefore -ErrorAction SilentlyContinue
        if ([int]$before -ne 0) { Write-Host 'Remote Desktop is off again.' } else { Write-Host 'Remote Desktop was on before WinKit: left on.' }
    } else {
        Write-Host 'WinKit had not turned Remote Desktop on: left as it is.'
    }
    Write-Host 'The Apple VM firewall rules for Remote Desktop are removed.'
    exit 0
}

$edition = Get-Edition
$caption = ''
try { $caption = (Get-CimInstance Win32_OperatingSystem).Caption } catch {}
Write-Host "Windows edition: $caption ($edition)"

if ($edition -like 'Core*' -or $caption -match 'Home') {
    Write-Host ''
    Write-Host 'Windows Home cannot accept Remote Desktop connections (it can only connect to other PCs).' -ForegroundColor Yellow
    Write-Host 'Instead you can:'
    Write-Host '  - Use SSH: double-click SSH-SETUP.bat, then forward SSH in the app (Settings > Port forwarding).'
    Write-Host '  - Upgrade to Windows Pro: Settings > System > Activation > Upgrade your edition of Windows.'
    Write-Host '  - Install a remote-control app inside Windows that runs its own server (for example a VNC server),'
    Write-Host '    and forward its port in the app (Settings > Port forwarding > Custom).'
    exit 2
}

# Remember how it was, once, so that -Uninstall can put it back.
if (-not (Test-Path -LiteralPath $state)) { New-Item -Path $state -Force | Out-Null }
$saved = $null
try { $saved = (Get-ItemProperty -LiteralPath $state -ErrorAction Stop).RdpDenyBefore } catch {}
if ($null -eq $saved) {
    $deny = 1
    try { $deny = [int](Get-ItemProperty -LiteralPath $ts -ErrorAction Stop).fDenyTSConnections } catch {}
    New-ItemProperty -LiteralPath $state -Name RdpDenyBefore -Value $deny -PropertyType DWord -Force | Out-Null
}

Set-ItemProperty -LiteralPath $ts -Name fDenyTSConnections -Value 0
# Network Level Authentication: the password is checked before a session starts.
Set-ItemProperty -LiteralPath "$ts\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1
try { Start-Service -Name TermService -ErrorAction Stop } catch { Write-Host "  Remote Desktop service: $($_.Exception.Message)" -ForegroundColor Yellow }

$port = Get-RdpPort
Remove-Rules
New-NetFirewallRule -Name 'AppleVM-RDP-TCP' -DisplayName "Apple VM: Remote Desktop (TCP $port)" -Direction Inbound `
    -Protocol TCP -LocalPort $port -Action Allow -Profile Any -RemoteAddress Any | Out-Null
New-NetFirewallRule -Name 'AppleVM-RDP-UDP' -DisplayName "Apple VM: Remote Desktop (UDP $port)" -Direction Inbound `
    -Protocol UDP -LocalPort $port -Action Allow -Profile Any -RemoteAddress Any | Out-Null

$who = "$env:USERDOMAIN\$env:USERNAME"
try {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $ms = Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$sid\IdentityCache\$sid" -ErrorAction Stop
    if ($ms.UserName) { $who = "MicrosoftAccount\$($ms.UserName)" }
} catch {}

# Windows refuses Remote Desktop sign-ins (and every other network sign-in) for an account with a blank
# password. A Microsoft account always has one; a local account may not (images made without a password).
# The test: a network logon with an empty password fails with 1327 (account restriction: blank password) or
# succeeds when the password is blank, and fails with 1326 (wrong password) when there is one. Nothing is
# changed: the person sets a password themselves.
$blank = $false
if ($who -notlike 'MicrosoftAccount\*') {
    try {
        Add-Type -Namespace WinKit -Name BlankCheck -MemberDefinition @'
[DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool LogonUser(string user, string domain, string password, int type, int provider, out IntPtr token);
[DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
'@ -ErrorAction Stop
        $tok = [IntPtr]::Zero
        $ok = [WinKit.BlankCheck]::LogonUser($env:USERNAME, '.', '', 3, 0, [ref]$tok)  # LOGON32_LOGON_NETWORK
        $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($ok) { [void][WinKit.BlankCheck]::CloseHandle($tok); $blank = $true }
        elseif ($err -eq 1327) { $blank = $true }
    } catch {}
}

Write-Host ''
Write-Host "Remote Desktop is on (port $port, TCP and UDP), with the firewall open for it." -ForegroundColor Green
Write-Host ''
Write-Host 'Next, on the iPhone: Settings > Network > Server mode > Add a Remote Desktop forward'
Write-Host '(or Port forwarding > Add a port forward > Remote Desktop), then Test connection there.'
Write-Host '  "This iPhone only": a Remote Desktop app on the same iPhone connects to 127.0.0.1 (or [::1]).'
Write-Host '  "Local network" or "VPN": other devices connect to an address the app shows, over IPv4 or IPv6.'
Write-Host "Sign in as: $who"
Write-Host 'The account needs a password (a PIN is not enough). For a Microsoft account, use its email and password,'
Write-Host 'turn off "only allow Windows Hello sign-in for Microsoft accounts" (Settings > Accounts > Sign-in options),'
Write-Host 'and if you only ever signed in with the PIN, sign in once with the password on this screen first.'
Write-Host 'Let the Remote Desktop client use UDP. To hand a Remote Desktop session back to the app''s screen without'
Write-Host 'signing in again, run C:\WinKit\RETURN-TO-SCREEN.bat inside it.'
if ($blank) {
    Write-Host ''
    Write-Host "This account ($env:USERNAME) has no password, and Windows refuses Remote Desktop sign-ins without one." -ForegroundColor Yellow
    Write-Host 'Set a password first: press Ctrl+Alt+Del (the app: Shortcuts > Ctrl + Alt + Del) > Change a password,' -ForegroundColor Yellow
    Write-Host 'or Settings > Accounts > Sign-in options > Password. WinKit does not set one for you.' -ForegroundColor Yellow
}
Write-Host 'Connections work while the app is in the foreground, and in the background too with the app''s Server mode'
Write-Host '(Windows keeps running there without host 3D; the app can switch to 2D without restarting Windows).'
Write-Host 'To undo: run enable_rdp.ps1 -Uninstall as administrator.'
exit 0
