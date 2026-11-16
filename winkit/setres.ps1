# Shows Windows only on the VirtIO GPU 3D display, sets it to the size the iPhone asks for and sets Windows'
# scale for it (live, no sign-out). Run from C:\WinKit (winkit.ps1 does) or the WINKIT drive.
#   powershell -ExecutionPolicy Bypass -File setres.ps1
# The size comes from http://10.0.2.4/res.txt: "WxH@scale" (e.g. "2576x1812@250") or just "WxH".
# What Windows took goes back to the app as res_applied.txt (the app's Display settings show it), the
# details as setres.txt. The WinKit helper (cli_setup.ps1) does the same by itself whenever res.txt changes.
$ErrorActionPreference = 'Continue'
$out = @("setres $(Get-Date -Format s)")

# WinKitDisplay.cs: next to this script, in C:\WinKit, or on the WINKIT drive
$cs = $null
$here = $PSScriptRoot
$places = @()
if ($here) { $places += (Join-Path $here 'WinKitDisplay.cs') }
$places += 'C:\WinKit\WinKitDisplay.cs'
try { Get-Volume -FileSystemLabel 'WINKIT' -ErrorAction Stop | ForEach-Object { if ($_.DriveLetter) { $places += "$($_.DriveLetter):\WinKitDisplay.cs" } } } catch {}
foreach ($p in $places) { if (Test-Path $p) { $cs = $p; break } }

$want = '1280x960'
try { $want = (Invoke-RestMethod 'http://10.0.2.4/res.txt').Trim() } catch {}
$w = 0; $h = 0; $scale = 0
if ($want -match '^(\d+)x(\d+)(@(\d+))?$') {
    $w = [int]$Matches[1]; $h = [int]$Matches[2]
    if ($Matches[4]) { $scale = [int]$Matches[4] }
}
$report = ''
try {
    if (-not $cs) { throw 'WinKitDisplay.cs not found (copy the whole WINKIT drive to C:\WinKit)' }
    & "$env:SystemRoot\System32\DisplaySwitch.exe" /internal
    Start-Sleep 4
    if (-not ('WinKitDisplay' -as [type])) { Add-Type -Path $cs -ErrorAction Stop }
    $out += [WinKitDisplay]::Apply($w, $h, $scale, 1500, [ref]$report)
    Start-Sleep 2
    $out += [WinKitDisplay]::Apply($w, $h, $scale, 0, [ref]$report)
} catch { $out += "failed: $_" }
$p = Join-Path $env:TEMP 'setres.txt'
$out | Out-File -Encoding ascii $p
try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri 'http://10.0.2.4/setres.txt' -InFile $p | Out-Null } catch {}
if ($report) {
    $r = Join-Path $env:TEMP 'res_applied.txt'
    [IO.File]::WriteAllText($r, $report)
    try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri 'http://10.0.2.4/res_applied.txt' -InFile $r | Out-Null } catch {}
}
