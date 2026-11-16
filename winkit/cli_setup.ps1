# WinKit: the background helper that runs what the app's toolbar asks for (e.g. the Claude Code installer),
# so nothing has to be typed into Windows by simulated keystrokes. It starts hidden with every logon (a
# shortcut in the Startup folder); the desktop starts as usual.
# Also removes the logon shell hook of the former "command line only" mode, if an older WinKit put it there
# (it ran a script in place of the desktop and showed console windows at every start).
# -Remove takes the helper away too. No administrator rights needed.
#   powershell -ExecutionPolicy Bypass -File cli_setup.ps1 [-Remove] [-NoShutdown]
param([switch]$Remove, [switch]$NoShutdown)  # -NoShutdown: accepted for older callers, nothing to do
$dir = Join-Path $env:LOCALAPPDATA 'WinKit'
$agent = Join-Path $dir 'agent.ps1'
$apps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
$startup = [Environment]::GetFolderPath('Startup')
$link = Join-Path $startup 'WinKitHelper.lnk'
$wl = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon'

# ---- the former command-line mode: Windows' own shell again, and its files gone
Remove-ItemProperty -Path $wl -Name 'Shell' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'WinKitCli' -ErrorAction SilentlyContinue
foreach ($f in (Join-Path $dir 'shell.cmd'), (Join-Path $dir 'restore.cmd'), (Join-Path $dir 'fixshell.cmd'),
               (Join-Path $dir 'clishell.cmd'), (Join-Path $startup 'WinKitCli.cmd'), (Join-Path $startup 'WinKitCli.lnk'),
               (Join-Path $apps 'desktop.cmd')) {
    Remove-Item $f -ErrorAction SilentlyContinue
}

# ---- a helper already running: stopped (started again below unless -Remove)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*WinKit\agent.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if ($Remove) {
    Remove-Item $agent, $link -ErrorAction SilentlyContinue
    [Microsoft.Win32.Registry]::CurrentUser.Flush()
    Write-Host 'WinKit helper removed.'
    return
}
New-Item -ItemType Directory -Force -Path $dir, $startup | Out-Null

# ---- the display code the helper loads (mode + Windows scale, see WinKitDisplay.cs)
$dispSrc = Join-Path $PSScriptRoot 'WinKitDisplay.cs'
if ($PSScriptRoot -and (Test-Path $dispSrc)) { Copy-Item -Force $dispSrc (Join-Path $dir 'WinKitDisplay.cs') }

# ---- the helper: asks the app for jobs and runs them, and keeps the display shaped as the app asks
@'
# WinKit helper: asks the app (http://10.0.2.4/agent_job.txt: a job id, then a command line) every
# second or two and starts each new job in its own console window. It also tells the app it is alive.
# Display: whenever http://10.0.2.4/res.txt changes ("WxH@scale"), it sets that mode and then Windows'
# scale, live, in this (the signed-in user's) session, and reports what Windows took (res_applied.txt).
$u = 'http://10.0.2.4'; $wc = New-Object Net.WebClient; $last = ''; $n = 0
try { $last = ($wc.DownloadString("$u/agent_job.txt") -split "`r?`n")[0].Trim() } catch {}   # a job from before this logon: not again
$disp = $false; $lastRes = ''; $attempted = ''; $retryAt = $null; $tries = 0
$cs = Join-Path $PSScriptRoot 'WinKitDisplay.cs'
try { if (Test-Path $cs) { Add-Type -Path $cs -ErrorAction Stop; $disp = $true } } catch {}
while ($true) {
    if (($n % 15) -eq 0) { try { [void]$wc.UploadString("$u/agent_alive.txt", 'PUT', (Get-Date -Format s)) } catch {} }
    Start-Sleep -Milliseconds 400
    if ($disp) {
        try {
            $r = $wc.DownloadString("$u/res.txt").Trim()
            if ($retryAt -and (Get-Date) -ge $retryAt) { $lastRes = ''; $retryAt = $null }
            if ($r -ne $lastRes -and $r -match '^(\d+)x(\d+)(@(\d+))?$') {
                if ($r -ne $attempted) { $tries = 0; $attempted = $r }   # a failed apply is retried 3 times, 5 s apart
                $lastRes = $r
                $sc = 0; if ($Matches[4]) { $sc = [int]$Matches[4] }
                $rep = ''
                $log = [WinKitDisplay]::Apply([int]$Matches[1], [int]$Matches[2], $sc, 800, [ref]$rep)
                try { [void]$wc.UploadString("$u/res_applied.txt", 'PUT', $rep) } catch {}
                try { [void]$wc.UploadString("$u/setres.txt", 'PUT', "helper $(Get-Date -Format s)`r`n$log") } catch {}
                if ($rep -match ' failed' -and $tries -lt 3) { $tries++; $retryAt = (Get-Date).AddSeconds(5) }
            }
        } catch {}
    }
    if ((($n++) % 4) -ne 0) { continue }
    try {
        $t = $wc.DownloadString("$u/agent_job.txt") -split "`r?`n"
        $id = $t[0].Trim()
        if ($id -and $id -ne $last -and $t.Count -gt 1 -and $t[1].Trim()) {
            $last = $id
            Start-Process cmd.exe -ArgumentList ('/c ' + $t[1].Trim())
        }
    } catch {}
}
'@ | Out-File -Encoding ascii $agent

# ---- started hidden at every logon
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
$sc.TargetPath = $ps
$sc.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $agent + '"'
$sc.WindowStyle = 7  # minimized: the moment before PowerShell hides itself shows nothing in front
$sc.Save()
[Microsoft.Win32.Registry]::CurrentUser.Flush()

# ---- and now, without waiting for the next logon
Start-Process $ps -WindowStyle Hidden -ArgumentList ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $agent + '"')

Write-Host ''
Write-Host 'WinKit helper installed: it starts hidden with every logon.' -ForegroundColor Green
Write-Host 'If an older WinKit had set up the command-line mode, it is removed: restart Windows from'
Write-Host 'Start > Power once (do not just close the app) so that Windows keeps the change.'
