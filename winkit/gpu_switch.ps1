# SPDX-License-Identifier: GPL-2.0-or-later
# WinKit: the app switches Windows between host 3D and plain 2D graphics without restarting Windows (the app's
# Settings > Network > Graphics, or More > Graphics; server mode uses it to keep Windows running in the background).
# The app offers the display device 3D or 2D from its next driver start and writes http://10.0.2.4/gpu_mode.txt
# ("seq=<n>" and "mode=3d" or "mode=2d"). A task here (WinKit Graphics, as SYSTEM) sees each new request and
# restarts only the display adapter (pnputil /restart-device), which then starts in the mode offered, and reports
# to the app (gpu_mode_applied.txt). Run by winkit.ps1 (START.bat); can be run on its own, elevated (also over SSH
# as an administrator). Safe to run again. Windows PowerShell 5.1.
#   powershell -ExecutionPolicy Bypass -File gpu_switch.ps1              set it up
#   powershell -ExecutionPolicy Bypass -File gpu_switch.ps1 -Uninstall   remove the task
# What a switch does to Windows: the screen goes black for a few seconds, and programs using 3D lose their
# graphics device (most recover, some crash). Without host 3D the 3D driver may not start; Windows then uses its
# basic display, and Remote Desktop is not affected.
param([switch]$Uninstall, [switch]$Watch)
$u = 'http://10.0.2.4'
$task = 'WinKit Graphics'

function Gpu {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'PCI\VEN_1AF4&DEV_1050*' } | Select-Object -First 1
}

# key=value lines for the app (ServerMode.swift reads them)
function Report($wc, $seq, $mode, $result, $detail) {
    $g = Gpu
    $status = 'missing'; $problem = ''; $name = ''
    if ($g) {
        $status = [string]$g.Status
        $name = [string]$g.FriendlyName
        try { $problem = [string](Get-PnpDeviceProperty -InstanceId $g.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction Stop).Data } catch {}
    }
    $detail = ([string]$detail -replace '[\r\n]+', ' ').Trim()
    $text = "seq=$seq`r`nmode=$mode`r`nresult=$result`r`nstatus=$status`r`nproblem=$problem`r`nname=$name`r`ndetail=$detail`r`ntime=$(Get-Date -Format s)`r`n"
    try { [void]$wc.UploadString("$u/gpu_mode_applied.txt", 'PUT', $text) } catch {}
}

if ($Watch) {
    # The task's loop (SYSTEM). The request read first is from before this start: Windows' display driver started
    # with whatever the device offered then, so it is only reported, never applied again.
    $wc = New-Object Net.WebClient
    $seen = $null
    while ($true) {
        try {
            $seq = ''; $mode = ''
            foreach ($l in ($wc.DownloadString("$u/gpu_mode.txt") -split "`r?`n")) {
                if ($l -match '^\s*seq=(\d+)') { $seq = $Matches[1] }
                elseif ($l -match '^\s*mode=(3d|2d)') { $mode = $Matches[1] }
            }
            if ($seq -and $mode) {
                if ($null -eq $seen) {
                    Report $wc $seq $mode 'at-start' 'Windows started with the mode offered then'
                } elseif ($seq -ne $seen) {
                    $g = Gpu
                    if (-not $g) {
                        Report $wc $seq $mode 'no-device' 'no VirtIO GPU (PCI\VEN_1AF4&DEV_1050) in Windows'
                    } else {
                        $out = (& pnputil.exe /restart-device "$($g.InstanceId)" 2>&1 | Out-String)
                        $rc = $LASTEXITCODE
                        # until the adapter has settled: started (OK) or failed to start (Error)
                        for ($i = 0; $i -lt 30; $i++) {
                            Start-Sleep -Milliseconds 500
                            $g = Gpu
                            if ($i -ge 3 -and $g -and ($g.Status -eq 'OK' -or $g.Status -eq 'Error')) { break }
                        }
                        if ($rc -eq 0) { Report $wc $seq $mode 'restarted' "pnputil exit 0" }
                        elseif ($rc -eq 3010) { Report $wc $seq $mode 'needs-restart' 'Windows can only apply it after a restart (pnputil 3010)' }
                        else { Report $wc $seq $mode 'failed' "pnputil exit $($rc): $out" }
                    }
                }
                $seen = $seq
            } elseif ($null -eq $seen) {
                $seen = ''
            }
        } catch {
            if ($null -eq $seen) { $seen = '' } # nothing asked yet (no file), or the share is not up yet
        }
        Start-Sleep -Seconds 2
    }
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host '  Administrator rights are needed: run START.bat (or this script from an elevated PowerShell).' -ForegroundColor Yellow
    exit 1
}

Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}
if ($Uninstall) {
    Write-Host '  The WinKit Graphics task is removed: the app can no longer switch 3D / 2D without a restart.'
    return
}

$dst = 'C:\WinKit'
$self = $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $dst | Out-Null
$to = Join-Path $dst 'gpu_switch.ps1'
if ($self -and ((Resolve-Path $self).Path -ne $to)) { Copy-Item -Force $self $to }
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$to`" -Watch"
$trg = New-ScheduledTaskTrigger -AtStartup
$prn = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
try {
    Register-ScheduledTask -TaskName $task -Action $act -Trigger $trg -Principal $prn -Settings $set -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $task
    Write-Host '  Graphics 3D / 2D without a restart: on (task WinKit Graphics)'
} catch { Write-Host "  Graphics task skipped: $($_.Exception.Message)" -ForegroundColor Yellow }
$g = Gpu
if ($g) { Write-Host "  Display adapter: $($g.FriendlyName) ($($g.Status))" }
else { Write-Host '  No VirtIO GPU found in Windows: the switch has nothing to restart.' -ForegroundColor Yellow }
