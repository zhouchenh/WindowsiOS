# SPDX-License-Identifier: GPL-2.0-or-later
# Manual launcher only. No elevation, installation, network, or system changes.
param(
    [string]$Executable = (Join-Path $PSScriptRoot 'SharedInitProbe.exe'),
    [string]$Report = (Join-Path $env:TEMP ('shared-init-probe-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.txt'))
)
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Run the ARM64 Windows PowerShell host.' }
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    throw 'SharedInitProbe.exe is missing. Build make shared-init-probe and copy the executable beside this launcher.'
}
$Report = [IO.Path]::GetFullPath($Report)
if ($Report.StartsWith('\\') -or ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($Report))).DriveType -eq 'Network') {
    throw 'The report must be on a local filesystem.'
}
if (Test-Path -LiteralPath $Report) { throw 'The report already exists; choose a new path.' }
Write-Host 'Manual GPU diagnostic: keep the VM/app in the foreground; run only when no other GPU test is active.'
Write-Host 'This test creates only its own D3D resources. Its watchdog exits only this probe process.'
Write-Host ('Local report: ' + $Report)
& $Executable 2>&1 | Set-Content -LiteralPath $Report -Encoding UTF8
$code = $LASTEXITCODE
Get-Content -LiteralPath $Report
Write-Host ('Probe exit code: ' + $code + ' (0 all pairs stable; 1 mismatch/error; 2 partial/unsupported; 3 setup error; 124 watchdog).')
exit $code
