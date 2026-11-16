# Guest side of the automatic smoothness test: moves a window around for a while, one step per
# composed frame, and reports how many frames Windows composed and how busy each CPU was.
# Started by the host script (scripts/bench/bench_device.py) through the app's typing channel:
#   powershell -ExecutionPolicy Bypass -c "irm http://10.0.2.4/bench.ps1 | iex"
$ErrorActionPreference = 'Continue'
$hostUrl = 'http://10.0.2.4'
$tag = 'run'; $seconds = 30
try { $cfg = (Invoke-RestMethod "$hostUrl/bench_cfg.txt").Trim() -split '\s+'; $tag = $cfg[0]; if ($cfg.Count -gt 1) { $seconds = [int]$cfg[1] } } catch {}
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class BenchNative {
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();
    [DllImport("dwmapi.dll")] public static extern int DwmGetCompositionTimingInfo(IntPtr hwnd, byte[] info);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    // DWM_TIMING_INFO (packed): cRefresh at 36, cFrame at 56; rateRefresh numerator/denominator at 4/8.
    public static bool Timing(out ulong refresh, out ulong frame, out double hz) {
        byte[] b = new byte[400]; BitConverter.GetBytes((uint)304).CopyTo(b, 0); refresh = frame = 0; hz = 0;
        if (DwmGetCompositionTimingInfo(IntPtr.Zero, b) != 0) return false;
        refresh = BitConverter.ToUInt64(b, 36); frame = BitConverter.ToUInt64(b, 56);
        uint n = BitConverter.ToUInt32(b, 4), d = BitConverter.ToUInt32(b, 8); hz = d != 0 ? (double)n / d : 0;
        return true;
    }
}
'@
$out = New-Object System.Collections.Generic.List[string]
$out.Add("tag=$tag"); $out.Add("seconds=$seconds"); $out.Add("started=" + (Get-Date -Format s))
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$out.Add("screen=$($scr.Width)x$($scr.Height)")
$form = New-Object System.Windows.Forms.Form
$form.Text = 'WindowsiOS bench'; $form.StartPosition = 'Manual'
$form.Width = [Math]::Min(900, [int]($scr.Width * 0.6)); $form.Height = [Math]::Min(600, [int]($scr.Height * 0.6))
$tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.Dock = 'Fill'
$tb.Text = ("The quick brown fox jumps over the lazy dog. " * 60); $form.Controls.Add($tb)
$form.TopMost = $true; $form.Show(); [System.Windows.Forms.Application]::DoEvents()
$ncpu = [Environment]::ProcessorCount
$pc = @(); for ($i = 0; $i -lt $ncpu; $i++) { $c = New-Object System.Diagnostics.PerformanceCounter('Processor', '% Processor Time', "$i"); [void]$c.NextValue(); $pc += $c }
$names = 'dwm', 'explorer', 'csrss', 'System'
$before = @{}; foreach ($n in $names) { $before[$n] = (Get-Process -Name $n -ErrorAction SilentlyContinue | Measure-Object -Property CPU -Sum).Sum }
$me = [System.Diagnostics.Process]::GetCurrentProcess(); $meBefore = $me.TotalProcessorTime.TotalSeconds
$r0 = [uint64]0; $f0 = [uint64]0; $hz = 0.0; $haveT = [BenchNative]::Timing([ref]$r0, [ref]$f0, [ref]$hz)
$rx = [Math]::Max(1, ($scr.Width - $form.Width) / 2 - 10); $ry = [Math]::Max(1, ($scr.Height - $form.Height) / 2 - 30)
$sw = [System.Diagnostics.Stopwatch]::StartNew(); $steps = 0; $worst = 0.0; $last = 0.0; $late = 0
while ($sw.Elapsed.TotalSeconds -lt $seconds) {
    $t = $sw.Elapsed.TotalSeconds
    $x = [int]($rx + $rx * [Math]::Sin($t * 2.0)); $y = [int]($ry + $ry * [Math]::Cos($t * 1.3))
    [void][BenchNative]::SetWindowPos($form.Handle, [IntPtr]::Zero, $x, $y, 0, 0, 0x0015)   # no size, no z-order, no activate
    [System.Windows.Forms.Application]::DoEvents()
    [void][BenchNative]::DwmFlush()                                                           # until the next composed frame
    $now = $sw.Elapsed.TotalMilliseconds; $dt = $now - $last; $last = $now
    if ($steps -gt 0) { if ($dt -gt $worst) { $worst = $dt }; if ($dt -gt 25) { $late++ } }
    $steps++
}
$el = $sw.Elapsed.TotalSeconds
$r1 = [uint64]0; $f1 = [uint64]0; [void][BenchNative]::Timing([ref]$r1, [ref]$f1, [ref]$hz)
$out.Add(('steps_per_s={0:F1}' -f ($steps / $el)))
$out.Add(('worst_step_ms={0:F0}' -f $worst)); $out.Add("steps_over_25ms=$late")
if ($haveT) { $out.Add(('dwm_refresh_hz={0:F1}' -f $hz)); $out.Add(('dwm_refreshes_per_s={0:F1}' -f (($r1 - $r0) / $el))); $out.Add(('dwm_frames_per_s={0:F1}' -f (($f1 - $f0) / $el))) }
$cpu = @(); foreach ($c in $pc) { $cpu += ('{0:F0}' -f $c.NextValue()) }
$out.Add('cpu_pct=' + ($cpu -join ','))
foreach ($n in $names) { $a = (Get-Process -Name $n -ErrorAction SilentlyContinue | Measure-Object -Property CPU -Sum).Sum; $out.Add(('proc_{0}_pct={1:F0}' -f $n, (100 * ($a - $before[$n]) / $el))) }
$out.Add(('proc_bench_pct={0:F0}' -f (100 * ($me.TotalProcessorTime.TotalSeconds - $meBefore) / $el)))
try { $g = Get-CimInstance Win32_VideoController | Select-Object -First 1; $out.Add("gpu=$($g.Name)"); $out.Add("mode=$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)@$($g.CurrentRefreshRate)") } catch {}
$out.Add("finished=" + (Get-Date -Format s))
$form.Close()
$p = Join-Path $env:TEMP 'bench_result.txt'; $out | Out-File -Encoding ascii $p
try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri "$hostUrl/bench_result.txt" -InFile $p | Out-Null } catch {}
