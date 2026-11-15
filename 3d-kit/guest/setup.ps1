# One command for everything on the Windows side. It looks at where the machine is and does the next step.
#   irm http://10.0.2.4/setup.ps1 | iex
$ErrorActionPreference = 'Continue'
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Asking for administrator rights: click Yes.' -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
        "irm http://10.0.2.4/setup.ps1 | iex; Read-Host 'Press Enter to close'")
    return
}
function Step($n, $text) { Write-Host ''; Write-Host "[$n] $text" -ForegroundColor Cyan }
$gpu = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*' }
$is3d = $gpu | Where-Object { $_.FriendlyName -like '*3D*' }

if (-not $is3d) {
    Step '1/3' 'Installing the 3D graphics driver (viogpu3d)...'
    Invoke-Expression (Invoke-RestMethod 'http://10.0.2.4/install_3d.ps1')
    Write-Host ''
    Write-Host 'Driver installed.' -ForegroundColor Green
    Write-Host 'NEXT: on the iPhone/iPad, turn on "3D" for this app (file gpu3d.on, see the README or run the Mac'
    Write-Host '      setup script), close the app completely, start it again, enable JIT, then run this same'
    Write-Host '      command once more in Windows.'
    return
}
if ($is3d.Status -ne 'OK') {
    Write-Host ''
    Write-Host 'The 3D driver is installed but not running.' -ForegroundColor Yellow
    Write-Host 'That means host 3D is still off: put the file gpu3d.on in the app''s Documents folder (the Mac setup'
    Write-Host 'script does it), close the app completely and start it again. Then run this command again.'
    return
}
Step '2/3' 'Fitting the screen (one desktop, device resolution)...'
Invoke-Expression (Invoke-RestMethod 'http://10.0.2.4/setres.ps1')
Write-Host 'Screen set.' -ForegroundColor Green

Step '3/3' 'Optional clean-up: stops search indexing, telemetry, automatic updates and removes widgets and inbox apps.'
Write-Host '      (No security updates afterwards. Windows Security settings are not touched.)'
$a = Read-Host 'Run the clean-up now? (y/N)'
if ($a -match '^[yY]') {
    Invoke-Expression (Invoke-RestMethod 'http://10.0.2.4/tune.ps1')
    Write-Host 'Clean-up done. Restart the app from the device (not Windows'' own Restart) to finish.' -ForegroundColor Green
}
Write-Host ''
Write-Host 'All set. Check with dxdiag: Display tab should say "Red Hat VirtIO GPU 3D controller", Feature Levels 11_0.' -ForegroundColor Green
