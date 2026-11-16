# Shows Windows only on the VirtIO GPU 3D display and sets it to the size the iPad asks for.
#   irm http://10.0.2.4/setres.ps1 | iex            (size from http://10.0.2.4/res.txt, e.g. "1386x956")
$ErrorActionPreference = 'Continue'
$src = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class Res {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
        public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
        public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr lp);

    public static string Run(int w, int h) {
        var sb = new System.Text.StringBuilder();
        for (uint i = 0; i < 8; i++) {
            var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            sb.AppendLine(dd.DeviceName + " '" + dd.DeviceString + "' flags=0x" + dd.StateFlags.ToString("x"));
            if (dd.DeviceString.IndexOf("VirtIO", StringComparison.OrdinalIgnoreCase) < 0) continue;
            var seen = new List<string>();
            var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(dm);
            bool have = false;
            for (int m = 0; EnumDisplaySettings(dd.DeviceName, m, ref dm); m++) {
                string k = dm.dmPelsWidth + "x" + dm.dmPelsHeight;
                if (!seen.Contains(k)) seen.Add(k);
                if (dm.dmPelsWidth == w && dm.dmPelsHeight == h) have = true;
            }
            sb.AppendLine("  modes: " + string.Join(" ", seen.ToArray()));
            var cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(cur);
            EnumDisplaySettings(dd.DeviceName, -1, ref cur);
            sb.AppendLine("  current: " + cur.dmPelsWidth + "x" + cur.dmPelsHeight + " wanted: " + w + "x" + h + " listed=" + have);
            if (cur.dmPelsWidth != w || cur.dmPelsHeight != h) {
                cur.dmPelsWidth = w; cur.dmPelsHeight = h;
                cur.dmFields = 0x80000 | 0x100000; /* DM_PELSWIDTH | DM_PELSHEIGHT */
                int r = ChangeDisplaySettingsEx(dd.DeviceName, ref cur, IntPtr.Zero, 1 /* CDS_UPDATEREGISTRY */, IntPtr.Zero);
                sb.AppendLine("  ChangeDisplaySettingsEx -> " + r);
            }
        }
        return sb.ToString();
    }
}
'@
$out = @("setres $(Get-Date -Format s)")
$want = '1280x960'
try { $want = (Invoke-RestMethod 'http://10.0.2.4/res.txt').Trim() } catch {}
$w, $h = $want -split 'x'
try {
    & "$env:SystemRoot\System32\DisplaySwitch.exe" /internal
    Start-Sleep 4
    Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
    $out += [Res]::Run([int]$w, [int]$h)
    Start-Sleep 2
    $out += [Res]::Run([int]$w, [int]$h)
} catch { $out += "failed: $_" }
$p = Join-Path $env:TEMP 'setres.txt'
$out | Out-File -Encoding ascii $p
try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri 'http://10.0.2.4/setres.txt' -InFile $p | Out-Null } catch {}
