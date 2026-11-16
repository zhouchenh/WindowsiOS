# WinKit: an OpenSSH server in Windows, key login only, so another computer can reach this Windows
# through a port forward of the app (Settings > Network, or HV_NET_FWD=lan:2222:22 in env.txt).
# Also gives slow-starting services more time (emulated Windows can miss the 30 s service start
# deadline, which shows up as "The Windows Installer Service could not be accessed").
# Safe to run again. Needs administrator rights: run it through SSH-SETUP.bat.
#   powershell -ExecutionPolicy Bypass -File ssh_setup.ps1
# Public keys come from ssh_authorized_keys.txt next to this script, or from
# http://10.0.2.4/ssh_authorized_keys.txt (the app's Shared folder). One OpenSSH public key per line.
$ErrorActionPreference = 'Stop'
$log = New-Object System.Collections.Generic.List[string]
function L([string]$m) { Write-Host "  $m"; $log.Add($m) }
function Send {
    try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri 'http://10.0.2.4/ssh_setup.log' -Body ($log -join "`r`n") | Out-Null } catch { }
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Host '  Administrator rights are needed: double-click SSH-SETUP.bat instead.' -ForegroundColor Yellow; return }

# --- 1. services get 3 minutes to start instead of 30 s (takes effect after a restart)
$ctl = 'HKLM:\SYSTEM\CurrentControlSet\Control'
New-ItemProperty -Path $ctl -Name 'ServicesPipeTimeout' -PropertyType DWord -Value 180000 -Force | Out-Null
L 'ServicesPipeTimeout = 180000 ms (after the next restart)'

# --- 2. Windows Installer: back to its normal manual start, and try to start it now
try {
    & sc.exe config msiserver start= demand | Out-Null
    $m = Get-Service msiserver
    L ("msiserver: start type {0}, status {1}" -f $m.StartType, $m.Status)
    if ($m.Status -ne 'Running') {
        try { Start-Service msiserver; L 'msiserver: started' } catch { L ("msiserver: could not start now: " + $_.Exception.Message) }
    }
} catch { L ("msiserver: " + $_.Exception.Message) }

# --- 3. the public keys
$keys = @()
$local = Join-Path $PSScriptRoot 'ssh_authorized_keys.txt'
if ($PSScriptRoot -and (Test-Path -LiteralPath $local)) { $keys = Get-Content -LiteralPath $local }
if (-not $keys) {
    try { $keys = (Invoke-WebRequest -UseBasicParsing -Uri 'http://10.0.2.4/ssh_authorized_keys.txt').Content -split "`r?`n" } catch { }
}
$keys = @($keys | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+|sk-\S+) \S+' })
if (-not $keys) {
    L 'No public key found: put ssh_authorized_keys.txt next to this script or in the app''s Shared folder.'
    Send; return
}
L ("public keys: {0}" -f $keys.Count)

# --- 4. OpenSSH server: Microsoft's Win32-OpenSSH for ARM64 (Windows Update is often off in this VM)
$pf = $env:ProgramW6432; if (-not $pf) { $pf = $env:ProgramFiles }
$dir = Join-Path $pf 'OpenSSH'
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    $zip = Join-Path $env:TEMP 'OpenSSH-ARM64.zip'
    $bundled = Join-Path $PSScriptRoot 'OpenSSH-ARM64.zip'
    if ($PSScriptRoot -and (Test-Path -LiteralPath $bundled)) { Copy-Item -LiteralPath $bundled $zip -Force; L 'OpenSSH: using the bundled zip' }
    else {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        L 'OpenSSH: downloading OpenSSH-ARM64.zip from github.com/PowerShell/Win32-OpenSSH ...'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-ARM64.zip' -OutFile $zip
    }
    $tmp = Join-Path $env:TEMP 'OpenSSH-unpack'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Move-Item -LiteralPath $inner.FullName $dir
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'install-sshd.ps1') | Out-Null
    L ("OpenSSH: installed in $dir")
} else { L 'OpenSSH: already installed' }

# --- 5. configuration: keys only
$data = Join-Path $env:ProgramData 'ssh'
New-Item -ItemType Directory -Force -Path $data | Out-Null
$cfg = Join-Path $data 'sshd_config'
if (-not (Test-Path -LiteralPath $cfg)) {
    $def = Join-Path $dir 'sshd_config_default'
    if (Test-Path -LiteralPath $def) { Copy-Item -LiteralPath $def $cfg }
}
if (Test-Path -LiteralPath $cfg) {
    $c = Get-Content -LiteralPath $cfg
    $c = $c -replace '^#?\s*PubkeyAuthentication\s+\S+', 'PubkeyAuthentication yes'
    $c = $c -replace '^#?\s*PasswordAuthentication\s+\S+', 'PasswordAuthentication no'
    if (-not ($c -match '^PasswordAuthentication ')) { $c = @('PasswordAuthentication no') + $c }
    if (-not ($c -match '^PubkeyAuthentication ')) { $c = @('PubkeyAuthentication yes') + $c }
    Set-Content -LiteralPath $cfg -Value $c -Encoding Ascii
    L 'sshd_config: PubkeyAuthentication yes, PasswordAuthentication no'
}
# administrators use ProgramData\ssh\administrators_authorized_keys (sshd_config's Match Group administrators)
$ak = Join-Path $data 'administrators_authorized_keys'
$have = @(); if (Test-Path -LiteralPath $ak) { $have = Get-Content -LiteralPath $ak }
$all = @($have + $keys | Where-Object { $_ } | Select-Object -Unique)
Set-Content -LiteralPath $ak -Value $all -Encoding Ascii
& icacls.exe $ak /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
# and the user's own file, for when the account is not an administrator
$uk = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
New-Item -ItemType Directory -Force -Path (Split-Path $uk) | Out-Null
$have = @(); if (Test-Path -LiteralPath $uk) { $have = Get-Content -LiteralPath $uk }
Set-Content -LiteralPath $uk -Value (@($have + $keys | Where-Object { $_ } | Select-Object -Unique)) -Encoding Ascii
L 'authorized keys written (administrators_authorized_keys and ~\.ssh\authorized_keys)'

# PowerShell as the login shell
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
$shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' -PropertyType String -Force -Value $shell | Out-Null

# --- 6. firewall and start
if (-not (Get-NetFirewallRule -Name 'WinKit-sshd' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'WinKit-sshd' -DisplayName 'OpenSSH Server (WinKit)' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
}
L 'firewall: TCP 22 allowed'
Set-Service sshd -StartupType Automatic
try { Restart-Service sshd -Force; L ("sshd: " + (Get-Service sshd).Status) }
catch { L ("sshd: did not start now (" + $_.Exception.Message + "). Restart Windows: it starts by itself, with the longer service timeout.") }
L ("user: " + [Environment]::UserName + "  guest address: 10.0.2.15")
L 'From another computer: ssh -p <forwarded port> <user>@<iPhone address>'
Send
