# WinKit: an SSH server in Windows, for other devices to reach through the app's port forwarding.
# Installs Windows' own OpenSSH Server (an optional feature: Windows downloads it, which needs the internet and can
# take a few minutes), starts it now and at every boot, and opens TCP 22 in the firewall for every network profile
# and from any address (connections through the phone arrive with the client's own address).
# Safe to run again. Needs administrator rights: run it through SSH-SERVER.bat.
#   powershell -ExecutionPolicy Bypass -File enable_ssh.ps1              turn it on
#   powershell -ExecutionPolicy Bypass -File enable_ssh.ps1 -Uninstall   undo: stop it, remove the rule, and
#                                                                         remove OpenSSH Server if WinKit added it
# Then, in the app: Settings > Port forwarding > Add a port forward > SSH (port 2222 on the iPhone -> 22 here).
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$state = 'HKLM:\SOFTWARE\AppleVM\WinKit'
$rule = 'AppleVM-SSH-TCP'

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host '  Administrator rights are needed: double-click SSH-SERVER.bat instead.' -ForegroundColor Yellow
    exit 1
}

function Get-SshCapability {
    try { return Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1 }
    catch { return $null }
}
function Get-Marker {
    try { return [int](Get-ItemProperty -LiteralPath $state -ErrorAction Stop).SshInstalledByWinKit } catch { return 0 }
}

if ($Uninstall) {
    Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
    if (Get-Service -Name sshd -ErrorAction SilentlyContinue) {
        Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
        Set-Service -Name sshd -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host 'SSH server stopped and disabled.'
    }
    if ((Get-Marker) -eq 1) {
        $cap = Get-SshCapability
        if ($cap -and $cap.State -eq 'Installed') {
            Write-Host "Removing $($cap.Name)..."
            try { Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null }
            catch { Write-Host "  could not remove it: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
        Remove-ItemProperty -LiteralPath $state -Name SshInstalledByWinKit -ErrorAction SilentlyContinue
    } else {
        Write-Host 'OpenSSH Server was there before WinKit: left installed.'
    }
    Write-Host 'The Apple VM firewall rule for SSH is removed.'
    exit 0
}

$cap = Get-SshCapability
if (-not $cap) {
    Write-Host 'This Windows does not offer OpenSSH Server as an optional feature.' -ForegroundColor Yellow
    Write-Host 'Look for it in Settings > System > Optional features > View features.'
    exit 2
}
if ($cap.State -ne 'Installed') {
    Write-Host "Installing $($cap.Name) (Windows downloads it; this can take a few minutes)..."
    try {
        Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  It did not install: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host '  Check that Windows is online and Windows Update is not paused or turned off, then run this again,'
        Write-Host '  or add it in Settings > System > Optional features > View features > OpenSSH Server.'
        exit 3
    }
    if (-not (Test-Path -LiteralPath $state)) { New-Item -Path $state -Force | Out-Null }
    New-ItemProperty -LiteralPath $state -Name SshInstalledByWinKit -Value 1 -PropertyType DWord -Force | Out-Null
}

Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue
New-NetFirewallRule -Name $rule -DisplayName 'Apple VM: SSH server (TCP 22)' -Direction Inbound -Protocol TCP `
    -LocalPort 22 -Action Allow -Profile Any -RemoteAddress Any | Out-Null

Write-Host ''
Write-Host 'The SSH server is running (port 22), now and at every start, with the firewall open for it.' -ForegroundColor Green
Write-Host ''
Write-Host 'Next, on the iPhone: Settings > Port forwarding > Add a port forward > SSH.'
Write-Host "Then from another device:  ssh -p 2222 $env:USERNAME@<the address the app shows>"
Write-Host 'Sign in with the Windows account password (for a Microsoft account, its password; a PIN does not work).'
Write-Host 'Keys: administrators use C:\ProgramData\ssh\administrators_authorized_keys, others ~\.ssh\authorized_keys.'
Write-Host 'Connections only work while the app is open in the foreground on the iPhone.'
Write-Host 'To undo: run enable_ssh.ps1 -Uninstall as administrator.'
exit 0
