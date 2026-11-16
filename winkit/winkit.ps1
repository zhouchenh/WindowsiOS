# WinKit: completes a fresh Windows 11 ARM64 in WindowsiOS without a Mac.
#   network driver -> 3D driver -> switches host 3D on -> (after the app restarts) fits the screen by itself.
#   Also installs WinIOS Browser (oauth_setup.ps1), so that sign-in links open in Safari on the iPhone, and
#   the helpers that run in the signed-in session: the display helper (Windows' size and scale follow the
#   app, WinKitDisplay.cs) and the keyboard focus agent (FocusAgent.cs), both from cli_setup.ps1, and the
#   clipboard helper (clipboard_setup.ps1). Running it again updates all of them.
#   Optional, on their own: SSH-SETUP.bat (OpenSSH server), REMOTE-DESKTOP.bat (Remote Desktop host).
# Run through START.bat. -Finish is what the logon task runs after the restart.
param([switch]$Finish)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$home3d = 'C:\WinKit'
$hostUrl = 'http://10.0.2.4'
function Say($t, $c = 'Cyan') { Write-Host ''; Write-Host $t -ForegroundColor $c }
function Gpu { Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*' } }
function HostUp { try { Invoke-WebRequest -UseBasicParsing -Uri "$hostUrl/" -TimeoutSec 4 | Out-Null; $true } catch { $_.Exception.Response -ne $null } }
function PutText($name, $text) {
    $p = Join-Path $env:TEMP $name
    [IO.File]::WriteAllText($p, $text)
    try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri "$hostUrl/$name" -InFile $p -TimeoutSec 10 | Out-Null; $true } catch { $false }
}

if ($Finish) {
    # After the restart: wait for the 3D driver, fit the screen, then remove this task.
    for ($i = 0; $i -lt 30; $i++) { if ((Gpu | Where-Object { $_.FriendlyName -like '*3D*' -and $_.Status -eq 'OK' })) { break }; Start-Sleep 4 }
    $g = Gpu | Where-Object { $_.FriendlyName -like '*3D*' }
    if ($g -and $g.Status -eq 'OK') {
        Start-Sleep 8
        & (Join-Path $home3d 'setres.ps1')
        Unregister-ScheduledTask -TaskName 'WinKit Finish' -Confirm:$false -ErrorAction SilentlyContinue
    }
    return
}

Say '=== WinKit setup ===' 'Green'
New-Item -ItemType Directory -Force -Path $home3d | Out-Null
Copy-Item -Recurse -Force (Join-Path $here '*') $home3d

Say '[1/5] Network driver (NetKVM)'
$net = Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4*' -and $_.Status -eq 'OK' }
if ($net) { Write-Host '  already installed' }
else {
    pnputil /add-driver (Join-Path $home3d 'NetKVM\netkvm.inf') /install | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
}

Say '[2/5] 3D graphics driver (viogpu3d)'
$g = Gpu
if ($g | Where-Object { $_.FriendlyName -like '*3D*' }) { Write-Host '  already installed' }
else {
    $txt = pnputil /enum-drivers | Out-String
    foreach ($b in ($txt -split "(\r?\n){2,}")) {
        if ($b -match 'Original Name:\s+viogpudo\.inf' -and $b -match 'Published Name:\s+(oem\d+\.inf)') { pnputil /delete-driver $Matches[1] /uninstall /force | Out-Null }
    }
    pnputil /add-driver (Join-Path $home3d 'viogpu3d\viogpu3d.inf') /install | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
}

Say '[3/5] Switching 3D on in the app'
$up = $false
for ($i = 0; $i -lt 20; $i++) { if (HostUp) { $up = $true; break }; Start-Sleep 3 }
$switched = $up -and (PutText 'gpu3d.on' 'on')
if ($switched) { Write-Host '  done (takes effect the next time the app starts)' }
else {
    Write-Host '  Could not reach the app over the network yet.' -ForegroundColor Yellow
    Write-Host '  Restart the app and run START.bat again, or create a file named gpu3d.on (any content)' -ForegroundColor Yellow
    Write-Host '  in the app''s folder with the Files app.' -ForegroundColor Yellow
}

# Fit the screen automatically at the first logon after the 3D driver is running.
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$home3d\winkit.ps1`" -Finish"
$trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$prn = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'WinKit Finish' -Action $act -Trigger $trg -Principal $prn -Force | Out-Null

$is3dOk = Gpu | Where-Object { $_.FriendlyName -like '*3D*' -and $_.Status -eq 'OK' }
if ($is3dOk) {
    Write-Host '  3D is already running: fitting the screen now'
    & (Join-Path $home3d 'setres.ps1')
    Unregister-ScheduledTask -TaskName 'WinKit Finish' -Confirm:$false -ErrorAction SilentlyContinue
}

Say '[4/5] Optional clean-up'
Write-Host '  Stops search indexing, telemetry and automatic updates, removes widgets and inbox apps.'
Write-Host '  (No security updates afterwards. Windows Security settings are not touched.)'
if ((Read-Host '  Run it now? (y/N)') -match '^[yY]') {
    Write-Host '  working: this takes a few minutes, please wait...' -ForegroundColor Yellow
    & (Join-Path $home3d 'tune.ps1')
    Write-Host '  clean-up done'
}

Say '[5/5] Sign-in links in Safari on the iPhone (OAuth bridge)'
Write-Host '  Installs WinIOS Browser: links that Windows apps open (e.g. "Sign in with Google") go to Safari on'
Write-Host '  the iPhone, with its saved passwords, passkeys and Face ID, and the sign-in comes back to Windows.'
try { & (Join-Path $home3d 'oauth_setup.ps1') } catch { Write-Host "  skipped: $($_.Exception.Message)" -ForegroundColor Yellow }

Say 'Helpers: display size and scale, keyboard focus, clipboard'
# The background helper (the app's toolbar jobs, e.g. Claude Code, and the display: Windows' mode and scale
# follow the app live) and the keyboard focus agent (the iPhone keyboard comes up in text boxes, Chinese and
# emoji typing). Also removes the old command-line mode's logon hook. Installs or updates; no restart needed.
try { & (Join-Path $home3d 'cli_setup.ps1') | Out-Null } catch { Write-Host "  helper skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
# What is copied in Windows appears on the iPhone, and the app's paste button sends the iPhone's to Windows.
try { & (Join-Path $home3d 'clipboard_setup.ps1') } catch { Write-Host "  clipboard skipped: $($_.Exception.Message)" -ForegroundColor Yellow }

Say 'Optional: user name'
Write-Host '  The image signs in as the account it was made with. You can give it your own name'
Write-Host '  (later too: RENAME-USER.bat in C:\WinKit).'
try { & (Join-Path $home3d 'rename_user.ps1') } catch { Write-Host "  skipped: $($_.Exception.Message)" -ForegroundColor Yellow }

Say '=== Done ===' 'Green'
if (-not $is3dOk) {
    Write-Host 'NOW: close the app completely on the device (swipe it away), open it again and enable JIT'
    Write-Host '     with StikDebug as usual. After Windows logs in, the screen fits itself within a minute.'
    Write-Host '     Do not use Windows'' own Restart.'
}
Write-Host 'BEFORE closing the app: shut Windows down from Start > Power once. That keeps the user settings made here'
Write-Host '(user name); swiping the app away without it can lose them.' 
Write-Host 'Check with dxdiag: Display > "Red Hat VirtIO GPU 3D controller", Feature Levels 11_0.'
Write-Host 'If the screen ever stays black: delete gpu3d.on from the app''s Shared folder in the Files app and restart the app.'
Write-Host 'Optional: SSH-SETUP.bat (SSH server, key login) and REMOTE-DESKTOP.bat (Remote Desktop) in C:\WinKit, then'
Write-Host 'Settings > Port forwarding in the app to reach Windows from other devices.'
