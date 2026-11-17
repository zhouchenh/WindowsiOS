# SPDX-License-Identifier: GPL-2.0-or-later
# WinKit: Windows' clock follows the iPhone. Run by winkit.ps1 (START.bat); can be run on its own, elevated
# (also over SSH as an administrator). Safe to run again.
#  - The app's real-time clock counts UTC: Windows is told to read it as UTC (RealTimeIsUniversal=1). Without
#    it Windows shows UTC as if it were local time. It is read at boot: it takes effect after Windows is shut
#    down from Start > Power and the machine is started again from the app (not Windows' own Restart).
#  - Windows Time (w32time) starts with Windows and syncs with time.windows.com and pool.ntp.org every hour,
#    and corrects any difference: Windows' clock stands still while the iPhone sleeps.
#  - A task (WinKit Clock, as SYSTEM) resyncs at once whenever the app comes back to the front
#    (http://10.0.2.4/resumed.txt changes).
#  - Windows' time zone is set once to the iPhone's (http://10.0.2.4/tz.txt); afterwards the WinKit helper
#    (cli_setup.ps1) keeps it matched, without administrator rights.
#   powershell -ExecutionPolicy Bypass -File clock_setup.ps1              set it up
#   powershell -ExecutionPolicy Bypass -File clock_setup.ps1 -Uninstall   RealTimeIsUniversal and the task removed
#                                                                         (w32time stays as it is)
# What the RTC counts comes from the app (tz.txt's "rtc=" line): with the app's rtc-localtime.on it counts local
# time, and this script removes RealTimeIsUniversal instead of setting it (the two must never be combined).
param([switch]$Uninstall, [switch]$Watch)
$u = 'http://10.0.2.4'
$task = 'WinKit Clock'

if ($Watch) {
    # The task's loop (SYSTEM): a new line in resumed.txt means the app was in the background, where Windows'
    # clock stood still: resync now. The first line read is only remembered.
    $wc = New-Object Net.WebClient; $seen = $null
    while ($true) {
        try {
            $m = $wc.DownloadString("$u/resumed.txt").Trim()
            if ($seen -ne $null -and $m -ne $seen) {
                if ((Get-Service w32time).Status -ne 'Running') { Start-Service w32time -ErrorAction SilentlyContinue }
                & w32tm.exe /resync /nowait | Out-Null
            }
            $seen = $m
        } catch { if ($seen -eq $null) { $seen = '' } }
        Start-Sleep -Seconds 3
    }
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host '  Administrator rights are needed: run START.bat (or this script from an elevated PowerShell).' -ForegroundColor Yellow
    exit 1
}
$tzi = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
$w32 = 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time'

Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}

if ($Uninstall) {
    Remove-ItemProperty -Path $tzi -Name 'RealTimeIsUniversal' -ErrorAction SilentlyContinue
    Write-Host '  RealTimeIsUniversal removed (Windows reads the RTC as local time again) and the WinKit Clock task.'
    Write-Host '  Shut Windows down from Start > Power and start it again from the app.'
    return
}

# ---- 1. how Windows reads the RTC: as UTC, unless the app says it counts local time (rtc-localtime.on)
$rtcLocal = $false
try {
    $lines = (New-Object Net.WebClient).DownloadString("$u/tz.txt") -split "`r?`n"
    $rtcLocal = @($lines | Where-Object { $_.Trim() -eq 'rtc=localtime' }).Count -gt 0
} catch { } # an older app, or no share: its RTC counts UTC
$was = (Get-ItemProperty -Path $tzi -Name 'RealTimeIsUniversal' -ErrorAction SilentlyContinue).RealTimeIsUniversal
if ($rtcLocal) {
    Remove-ItemProperty -Path $tzi -Name 'RealTimeIsUniversal' -ErrorAction SilentlyContinue
    if ($was -eq 1) { Write-Host '  RTC read as local time (the app counts local time): RealTimeIsUniversal removed (takes effect after a shut-down and a start from the app)' }
    else { Write-Host '  RTC read as local time (the app counts local time)' }
} else {
    & reg.exe add 'HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' /v RealTimeIsUniversal /t REG_DWORD /d 1 /f | Out-Null
    if ($was -eq 1) { Write-Host '  RTC read as UTC: already set' }
    else { Write-Host '  RTC read as UTC: set (takes effect after a shut-down and a start from the app)' }
}

# ---- 2. Windows Time: starts with Windows, hourly, any correction size (the clock stands still in sleep)
& sc.exe config w32time start= delayed-auto | Out-Null
& reg.exe add "$w32\TimeProviders\NtpClient" /v SpecialPollInterval /t REG_DWORD /d 3600 /f | Out-Null
& reg.exe add "$w32\Config" /v MaxPosPhaseCorrection /t REG_DWORD /d 0xFFFFFFFF /f | Out-Null
& reg.exe add "$w32\Config" /v MaxNegPhaseCorrection /t REG_DWORD /d 0xFFFFFFFF /f | Out-Null
Start-Service w32time -ErrorAction SilentlyContinue
& w32tm.exe /config '/manualpeerlist:time.windows.com,0x9 pool.ntp.org,0x9' /syncfromflags:manual /update | Out-Null
Restart-Service w32time -ErrorAction SilentlyContinue
& w32tm.exe /resync /nowait | Out-Null
Write-Host "  Windows Time: $((Get-Service w32time).Status), syncs with time.windows.com and pool.ntp.org every hour"

# ---- 3. the resync when the app comes back to the front: a task as SYSTEM, from C:\WinKit
$dst = 'C:\WinKit'
$self = $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $dst | Out-Null
foreach ($f in 'clock_setup.ps1', 'WinKitTz.cs') {
    $src = Join-Path (Split-Path -Parent $self) $f
    $to = Join-Path $dst $f
    if ((Test-Path $src) -and ((Resolve-Path $src).Path -ne $to)) { Copy-Item -Force $src $to }
}
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dst\clock_setup.ps1`" -Watch"
$trg = New-ScheduledTaskTrigger -AtStartup
$prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
try {
    Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Principal $prn -Settings $set -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $task
    Write-Host '  Resync when the app comes back to the front: on (task WinKit Clock)'
} catch { Write-Host "  Resync task skipped: $($_.Exception.Message)" -ForegroundColor Yellow }

# ---- 4. the iPhone's time zone, once (the helper keeps it matched afterwards)
$cs = Join-Path $dst 'WinKitTz.cs'
try {
    $z = ((New-Object Net.WebClient).DownloadString("$u/tz.txt") -split "`r?`n")[0].Trim()
    if (-not $z) { throw 'tz.txt is empty' }
    if (-not ('WinKitTz' -as [type])) { Add-Type -Path $cs -ErrorAction Stop }
    $rep = ''
    $win = [WinKitTz]::Apply($z, [ref]$rep)
    if ($win) { Write-Host "  Time zone: $win (the iPhone's $z)" }
    else { Write-Host "  Time zone not changed: $rep" -ForegroundColor Yellow }
} catch { Write-Host "  Time zone not changed now (the helper sets it): $($_.Exception.Message)" -ForegroundColor Yellow }

if ($was -ne 1) {
    Write-Host '  Note: until the shut-down and start from the app, the clock can be hours off, and it moves back' -ForegroundColor Yellow
    Write-Host '  once (files saved meanwhile can show a time in the future).' -ForegroundColor Yellow
}
