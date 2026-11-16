// WinKit display: sets the VirtIO GPU display to the mode the app asks for, then Windows' scale for that
// display, live, the way Settings > Display > Scale does (per-monitor DPI, no sign-out). Loaded with
// Add-Type by setres.ps1 and by the WinKit helper (agent.ps1, from cli_setup.ps1), which runs in the
// signed-in user's session: the DPI calls only work there.
// C# 5 (Windows PowerShell 5.1 compiles it with the .NET Framework compiler).
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32;

public static class WinKitDisplay {
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

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER { public int type; public int size; public LUID adapterId; public uint id; }

    // Undocumented, as used by Settings: -3 gets the scale range of a source, -4 sets it. Both are steps
    // relative to the scale Windows recommends for the current mode.
    [StructLayout(LayoutKind.Sequential)]
    public struct DPI_SCALE_GET { public DISPLAYCONFIG_DEVICE_INFO_HEADER header; public int minScaleRel; public int curScaleRel; public int maxScaleRel; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DPI_SCALE_SET { public DISPLAYCONFIG_DEVICE_INFO_HEADER header; public int scaleRel; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SOURCE_DEVICE_NAME {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_SOURCE_INFO { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_TARGET_INFO {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public int outputTechnology; public int rotation;
        public int scaling; public uint refreshNum; public uint refreshDen; public int scanLineOrdering;
        public int targetAvailable; public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PATH_INFO { public PATH_SOURCE_INFO sourceInfo; public PATH_TARGET_INFO targetInfo; public uint flags; }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr lp);
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths, ref uint numModes, IntPtr modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref DPI_SCALE_GET req);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref SOURCE_DEVICE_NAME req);
    [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref DPI_SCALE_SET req);

    // The scale steps Windows offers per monitor, in order: the relative steps index into this.
    static readonly int[] Steps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };
    const uint QDC_ONLY_ACTIVE_PATHS = 2;
    const int MODE_SIZE = 64; // sizeof(DISPLAYCONFIG_MODE_INFO)

    /// The VirtIO GPU display (\\.\DISPLAYn), else the primary one.
    public static string FindDisplay(StringBuilder log) {
        string primary = null, virtio = null;
        for (uint i = 0; i < 16; i++) {
            DISPLAY_DEVICE dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            if (log != null) log.AppendLine(dd.DeviceName + " '" + dd.DeviceString + "' flags=0x" + dd.StateFlags.ToString("x"));
            if ((dd.StateFlags & 1) == 0) continue; // not attached to the desktop
            if ((dd.StateFlags & 4) != 0 && primary == null) primary = dd.DeviceName;
            if (virtio == null && dd.DeviceString.IndexOf("VirtIO", StringComparison.OrdinalIgnoreCase) >= 0) virtio = dd.DeviceName;
        }
        return virtio ?? primary;
    }

    public static bool CurrentMode(string dev, out int w, out int h) {
        DEVMODE cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(cur);
        bool ok = EnumDisplaySettings(dev, -1, ref cur);
        w = cur.dmPelsWidth; h = cur.dmPelsHeight;
        return ok;
    }

    /// The display path of a GDI device name (adapter and source id), for the DPI calls.
    static bool FindSource(string dev, out LUID adapter, out uint sourceId, StringBuilder log) {
        adapter = new LUID(); sourceId = 0;
        uint np, nm;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out np, out nm) != 0 || np == 0) { log.AppendLine("  no display paths"); return false; }
        PATH_INFO[] paths = new PATH_INFO[np];
        IntPtr modes = Marshal.AllocHGlobal((int)(Math.Max(nm, 1) * MODE_SIZE));
        try {
            int r = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero);
            if (r != 0) { log.AppendLine("  QueryDisplayConfig -> " + r); return false; }
        } finally { Marshal.FreeHGlobal(modes); }
        bool found = false;
        for (int i = 0; i < np; i++) {
            SOURCE_DEVICE_NAME sn = new SOURCE_DEVICE_NAME();
            sn.header.type = 1; // DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME
            sn.header.size = Marshal.SizeOf(sn);
            sn.header.adapterId = paths[i].sourceInfo.adapterId;
            sn.header.id = paths[i].sourceInfo.id;
            string name = DisplayConfigGetDeviceInfo(ref sn) == 0 ? sn.viewGdiDeviceName : "";
            if (!found || string.Equals(name, dev, StringComparison.OrdinalIgnoreCase)) {
                adapter = paths[i].sourceInfo.adapterId; sourceId = paths[i].sourceInfo.id; found = true;
                if (string.Equals(name, dev, StringComparison.OrdinalIgnoreCase)) break;
            }
        }
        return found;
    }

    static bool GetScale(LUID adapter, uint id, out int min, out int cur, out int max, out int rec) {
        DPI_SCALE_GET g = new DPI_SCALE_GET();
        g.header.type = -3; g.header.size = Marshal.SizeOf(g); g.header.adapterId = adapter; g.header.id = id;
        min = cur = max = rec = 0;
        if (DisplayConfigGetDeviceInfo(ref g) != 0) return false;
        int recIdx = Math.Abs(g.minScaleRel); // the smallest step is 100%: index 0
        rec = Steps[Math.Min(recIdx, Steps.Length - 1)];
        min = Steps[0];
        cur = Steps[Math.Max(0, Math.Min(Steps.Length - 1, recIdx + g.curScaleRel))];
        max = Steps[Math.Max(0, Math.Min(Steps.Length - 1, recIdx + g.maxScaleRel))];
        return true;
    }

    static int StepIndex(int percent) {
        int best = 0;
        for (int i = 0; i < Steps.Length; i++) if (Math.Abs(Steps[i] - percent) < Math.Abs(Steps[best] - percent)) best = i;
        return best;
    }

    /// Fallback: the per-monitor value Windows reads at sign-in (relative step), for every monitor it knows.
    static bool SetScaleRegistry(int rel, StringBuilder log) {
        try {
            using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Control Panel\Desktop\PerMonitorSettings", true)) {
                if (k == null) { log.AppendLine("  no PerMonitorSettings key"); return false; }
                int n = 0;
                foreach (string sub in k.GetSubKeyNames()) {
                    using (RegistryKey m = k.OpenSubKey(sub, true)) {
                        if (m == null) continue;
                        m.SetValue("DpiValue", rel, RegistryValueKind.DWord);
                        n++;
                    }
                }
                log.AppendLine("  registry DpiValue=" + rel + " for " + n + " monitor(s)");
                return n > 0;
            }
        } catch (Exception e) { log.AppendLine("  registry: " + e.Message); return false; }
    }

    /// Mode w x h (waiting up to graceMs for the driver to switch by itself first), then the scale
    /// (percent, 0: leave it). report: "WxH@S live|signout|failed min=.. max=.. rec=..", what Windows took.
    public static string Apply(int w, int h, int scale, int graceMs, out string report) {
        StringBuilder log = new StringBuilder();
        report = "";
        string dev = FindDisplay(log);
        if (dev == null) { log.AppendLine("no display"); report = "0x0@0 failed"; return log.ToString(); }
        int cw, ch;
        CurrentMode(dev, out cw, out ch);
        log.AppendLine(dev + " current " + cw + "x" + ch + " wanted " + w + "x" + h + "@" + scale);
        if (w > 0 && h > 0 && (cw != w || ch != h)) {
            // the virtio-gpu driver usually takes the new preferred mode by itself: give it a moment
            for (int t = 0; t < graceMs && (cw != w || ch != h); t += 100) { Thread.Sleep(100); CurrentMode(dev, out cw, out ch); }
            if (cw != w || ch != h) {
                DEVMODE dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(dm);
                EnumDisplaySettings(dev, -1, ref dm);
                dm.dmPelsWidth = w; dm.dmPelsHeight = h;
                dm.dmFields = 0x80000 | 0x100000; // DM_PELSWIDTH | DM_PELSHEIGHT
                int r = ChangeDisplaySettingsEx(dev, ref dm, IntPtr.Zero, 1 /* CDS_UPDATEREGISTRY */, IntPtr.Zero);
                log.AppendLine("  ChangeDisplaySettingsEx -> " + r);
                for (int t = 0; t < 3000 && (cw != w || ch != h); t += 100) { Thread.Sleep(100); CurrentMode(dev, out cw, out ch); }
            } else {
                log.AppendLine("  the driver switched by itself");
            }
            Thread.Sleep(300); // let the mode settle: Windows recomputes its recommended scale for it
        }
        int min = 0, cur = 0, max = 0, rec = 0;
        string method = "live";
        LUID adapter; uint id;
        bool haveSource = FindSource(dev, out adapter, out id, log);
        bool haveScale = haveSource && GetScale(adapter, id, out min, out cur, out max, out rec);
        if (scale > 0) {
            if (!haveScale) {
                log.AppendLine("  the scale range is unavailable");
                method = "failed";
            } else {
                int want = Math.Max(min, Math.Min(max, scale)); // Windows caps the scale per mode
                int recIdx = StepIndex(rec);
                if (want != cur) {
                    DPI_SCALE_SET s = new DPI_SCALE_SET();
                    s.header.type = -4; s.header.size = Marshal.SizeOf(s); s.header.adapterId = adapter; s.header.id = id;
                    s.scaleRel = StepIndex(want) - recIdx;
                    int r = DisplayConfigSetDeviceInfo(ref s);
                    log.AppendLine("  scale " + cur + "% -> " + want + "% (rel " + s.scaleRel + ") -> " + r);
                    int m2, c2, x2, r2;
                    if (r == 0 && GetScale(adapter, id, out m2, out c2, out x2, out r2) && c2 == want) {
                        cur = c2;
                    } else if (SetScaleRegistry(s.scaleRel, log)) {
                        method = "signout";
                        cur = want;
                    } else {
                        method = "failed";
                    }
                }
            }
        }
        CurrentMode(dev, out cw, out ch);
        report = cw + "x" + ch + "@" + cur + " " + method + " min=" + min + " max=" + max + " rec=" + rec;
        log.AppendLine("  " + report);
        return log.ToString();
    }
}
