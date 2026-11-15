# Installs the VirtIO GPU 3D driver (viogpu3d / Neptune, D3D11 on the iPad's GPU) in place of viogpudo.
# Run from PowerShell:  irm http://10.0.2.4/install_3d.ps1 | iex
$ErrorActionPreference = 'Continue'
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Asking for administrator rights: click Yes.'
    Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
        "irm http://10.0.2.4/install_3d.ps1 | iex; Read-Host 'Press Enter to close'")
    return
}
$log = @()
function L($s) { $script:log += [string]$s; Write-Host $s }
$dir = Join-Path $env:TEMP 'viogpu3d'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$files = 'viogpu3d.inf','viogpu3d.cat','viogpu3d.sys','neptune_umd.dll','neptune_umd_arm64.dll','neptune_umd_ec.dll',
         'neptune_umd_x86.dll','vulkan_virtio.dll','virtio_icd.json','vgpusrv.exe','viogpuap.exe'
foreach ($f in $files) {
    try { Invoke-WebRequest -UseBasicParsing -Uri "http://10.0.2.4/viogpu3d/$f" -OutFile (Join-Path $dir $f) }
    catch { L "download $f failed: $_" }
}
L "downloaded: $((Get-ChildItem $dir).Count) files"

# Remove viogpudo (the 2D driver) so the 3D one binds the device.
$cur = pnputil /enum-drivers | Out-String
$blocks = $cur -split "(\r?\n){2,}"
foreach ($b in $blocks) {
    if ($b -match 'Original Name:\s+viogpudo\.inf' -and $b -match 'Published Name:\s+(oem\d+\.inf)') {
        L "removing viogpudo package $($Matches[1])"
        L ((pnputil /delete-driver $Matches[1] /uninstall /force) -join ' ')
    }
}
L ((pnputil /add-driver (Join-Path $dir 'viogpu3d.inf') /install) -join ' ')
Start-Sleep 5
Get-PnpDevice -Class Display | ForEach-Object { L ("{0} {1} {2}" -f $_.Status, $_.FriendlyName, $_.InstanceId) }
$p = Join-Path $env:TEMP 'install_3d_report.txt'
$log | Out-File -Encoding ascii $p
try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri 'http://10.0.2.4/install_3d_report.txt' -InFile $p | Out-Null } catch {}
Write-Host ''
Write-Host 'Done. The screen may flicker or go black for a few seconds while the driver starts.'
