# WinKit: the clipboard helper, which keeps Windows' clipboard in step with the iPhone's (docs/clipboard.md).
# Builds clipboard_agent.cs with Add-Type into %LOCALAPPDATA%\WinKit\WinKitClipboard.exe (no window, no
# console) and starts it at every logon in your own session through the scheduled task "WinKit Clipboard".
# The task also looks every 5 minutes and starts the helper again if it ever stopped.
# Safe to run again (it replaces the helper). -Remove takes it away. No administrator rights needed:
# CLIPBOARD.bat runs it, and START.bat (winkit.ps1) does too.
#   powershell -ExecutionPolicy Bypass -File clipboard_setup.ps1 [-Remove]
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$task = 'WinKit Clipboard'
$dir = Join-Path $env:LOCALAPPDATA 'WinKit'
$exe = Join-Path $dir 'WinKitClipboard.exe'
$src = Join-Path $PSScriptRoot 'clipboard_agent.cs'
$link = Join-Path ([Environment]::GetFolderPath('Startup')) 'WinKitClipboard.lnk'
$user = "$env:USERDOMAIN\$env:USERNAME"

# ---- a helper already running: stopped (started again below unless -Remove)
try { Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue } catch {}
try { Get-Process -Name 'WinKitClipboard' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Milliseconds 300

if ($Remove) {
    try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue } catch {}
    Remove-Item -LiteralPath $exe, (Join-Path $dir 'clipboard.log'), $link -Force -ErrorAction SilentlyContinue
    Write-Host '  WinKit clipboard helper removed.'
    return
}
if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "  clipboard_agent.cs is not next to this script ($PSScriptRoot): use a newer WinKit disk." -ForegroundColor Yellow
    return
}

# ---- the program. Built under a new name first: PowerShell may keep what it built open.
try {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $tmp = Join-Path $env:TEMP ('WinKitClipboard-' + [Guid]::NewGuid().ToString('N') + '.exe')
    Add-Type -Path $src -ReferencedAssemblies 'System.Windows.Forms' -OutputAssembly $tmp -OutputType WindowsApplication -IgnoreWarnings
    Copy-Item -LiteralPath $tmp -Destination $exe -Force
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "  built: $exe"
} catch {
    Write-Host "  Could not build the clipboard helper: $($_.Exception.Message)" -ForegroundColor Red
    return
}

# ---- started at every logon, in this user's session (the clipboard belongs to it), not elevated
$started = $false
try {
    $act = New-ScheduledTaskAction -Execute $exe
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $user
    # Every 5 minutes as well, for as long as the session lasts: IgnoreNew leaves a running helper alone.
    $trg.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 6 `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    $prn = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Settings $set -Principal $prn -Force `
        -Description 'Keeps the clipboard in step with the iPhone (WinKit, Apple VM).' | Out-Null
    Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $task
    $started = $true
} catch {
    # Without the task (refused by a policy, say): a shortcut in the Startup folder, no restarts.
    Write-Host "  scheduled task not set up ($($_.Exception.Message)): using the Startup folder" -ForegroundColor Yellow
    try {
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
        $sc.TargetPath = $exe
        $sc.Save()
    } catch {}
}
if (-not $started) { Start-Process -FilePath $exe }

# ---- is it running, and does the app answer?
Start-Sleep -Seconds 2
if (Get-Process -Name 'WinKitClipboard' -ErrorAction SilentlyContinue) {
    Write-Host '  WinKit clipboard helper running: it starts by itself with every logon.' -ForegroundColor Green
} else {
    Write-Host "  The helper did not stay running: see $(Join-Path $dir 'clipboard.log')" -ForegroundColor Yellow
}
try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://10.0.2.4/.henge/clipboard' -TimeoutSec 5
    if ($r.Headers['X-Henge-Seq']) { Write-Host '  The app answers: copy text in Windows and it is on the iPhone.' }
} catch {
    Write-Host '  The app does not answer yet (older app, or the network is not up): the helper keeps trying.' -ForegroundColor Yellow
}
