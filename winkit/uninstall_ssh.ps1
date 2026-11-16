# Undoes ssh_setup.ps1 (SSH-SETUP.bat): stops the SSH server and removes it if it is the copy SSH-SETUP put in
# C:\Program Files\OpenSSH (Windows' own optional-feature OpenSSH is only stopped and disabled), and removes its
# firewall rule and PowerShell login shell setting. The keys and host keys in C:\ProgramData\ssh and the longer
# service start timeout stay. Safe to run again.
# Run elevated:  powershell -ExecutionPolicy Bypass -File uninstall_ssh.ps1
$ErrorActionPreference = 'Continue'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host 'Run this as administrator.' -ForegroundColor Yellow; exit 1 }

$pf = $env:ProgramW6432; if (-not $pf) { $pf = $env:ProgramFiles }
$dir = Join-Path $pf 'OpenSSH'

$svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
if ($svc) {
    Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
    $path = ''
    try { $path = [string](Get-CimInstance Win32_Service -Filter "Name='sshd'").PathName } catch {}
    $uninstaller = Join-Path $dir 'uninstall-sshd.ps1'
    if ($path -like "*$dir*" -and (Test-Path -LiteralPath $uninstaller)) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $uninstaller | Out-Null
        Start-Sleep -Milliseconds 500
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "SSH server removed ($dir)."
    } else {
        Set-Service -Name sshd -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host 'SSH server stopped and disabled (it was not the copy SSH-SETUP installed, so it stays installed).'
    }
} else {
    Write-Host 'No SSH server is installed.'
}

Remove-NetFirewallRule -Name 'WinKit-sshd' -ErrorAction SilentlyContinue
try { Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -ErrorAction Stop } catch {}
Write-Host 'Firewall rule for TCP 22 removed.'
Write-Host 'Kept: C:\ProgramData\ssh (keys, host keys, sshd_config). Delete it by hand if you no longer need it.'
Write-Host 'Remember to remove the SSH port forward in the app too (Settings > Port forwarding).'
exit 0
