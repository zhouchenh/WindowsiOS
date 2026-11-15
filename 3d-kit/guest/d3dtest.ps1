# Calls D3D11CreateDevice the way dwm.exe does, on every DXGI adapter, and captures the driver's
# OutputDebugString lines (Triton/Neptune UMD) while doing it. Result goes to the iPad.
$ErrorActionPreference = 'Continue'
$src = @'
using System;
using System.Collections.Generic;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class D3DTest {
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr factory);
    [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(IntPtr adapter, int driverType, IntPtr software, uint flags,
        int[] levels, uint nLevels, uint sdk, out IntPtr device, out int level, out IntPtr context);
    [DllImport("gdi32.dll")] static extern int D3DKMTOpenAdapterFromLuid(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCreateDevice(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCreateContextVirtual(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCreatePagingQueue(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTDestroyDevice(IntPtr p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(IntPtr p);

    static void Kmt(StringBuilder sb, long luid) {
        IntPtr b = Marshal.AllocHGlobal(256);
        for (int i = 0; i < 256; i++) Marshal.WriteByte(b, i, 0);
        Marshal.WriteInt64(b, 0, luid);
        int st = D3DKMTOpenAdapterFromLuid(b);
        int hAdapter = Marshal.ReadInt32(b, 8);
        sb.AppendLine("  kmt OpenAdapterFromLuid st=0x" + st.ToString("x8") + " h=0x" + hAdapter.ToString("x"));
        if (st < 0) return;
        for (int i = 0; i < 256; i++) Marshal.WriteByte(b, i, 0);
        Marshal.WriteInt32(b, 0, hAdapter);
        st = D3DKMTCreateDevice(b);
        int hDevice = Marshal.ReadInt32(b, 12);
        sb.AppendLine("  kmt CreateDevice st=0x" + st.ToString("x8") + " h=0x" + hDevice.ToString("x"));
        if (st >= 0) {
            IntPtr c = Marshal.AllocHGlobal(256);
            for (int i = 0; i < 256; i++) Marshal.WriteByte(c, i, 0);
            Marshal.WriteInt32(c, 0, hDevice);      /* hDevice */
            Marshal.WriteInt32(c, 8, 1);            /* EngineAffinity */
            st = D3DKMTCreateContextVirtual(c);
            sb.AppendLine("  kmt CreateContextVirtual st=0x" + st.ToString("x8") + " h=0x" + Marshal.ReadInt32(c, 32).ToString("x"));
            for (int i = 0; i < 256; i++) Marshal.WriteByte(c, i, 0);
            Marshal.WriteInt32(c, 0, hDevice);
            st = D3DKMTCreatePagingQueue(c);
            sb.AppendLine("  kmt CreatePagingQueue st=0x" + st.ToString("x8") + " h=0x" + Marshal.ReadInt32(c, 8).ToString("x"));
            for (int i = 0; i < 256; i++) Marshal.WriteByte(c, i, 0);
            Marshal.WriteInt32(c, 0, hDevice);
            D3DKMTDestroyDevice(c);
        }
        for (int i = 0; i < 256; i++) Marshal.WriteByte(b, i, 0);
        Marshal.WriteInt32(b, 0, hAdapter);
        D3DKMTCloseAdapter(b);
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumAdapters1(IntPtr self, uint i, out IntPtr adapter);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int GetDesc(IntPtr self, IntPtr desc);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint Release(IntPtr self);

    static T Vt<T>(IntPtr obj, int slot) {
        IntPtr vt = Marshal.ReadIntPtr(obj);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, slot * IntPtr.Size), typeof(T));
    }

    static List<string> dbg = new List<string>();
    static volatile bool stop;

    static void Listen() {
        try {
            using (var mmf = MemoryMappedFile.CreateOrOpen("DBWIN_BUFFER", 4096))
            using (var ready = new EventWaitHandle(false, EventResetMode.AutoReset, "DBWIN_BUFFER_READY"))
            using (var data = new EventWaitHandle(false, EventResetMode.AutoReset, "DBWIN_DATA_READY"))
            using (var view = mmf.CreateViewAccessor(0, 4096)) {
                while (!stop) {
                    ready.Set();
                    if (!data.WaitOne(200)) continue;
                    int pid = view.ReadInt32(0);
                    byte[] b = new byte[4092];
                    view.ReadArray(4, b, 0, b.Length);
                    int n = Array.IndexOf(b, (byte)0);
                    string s = Encoding.ASCII.GetString(b, 0, n < 0 ? b.Length : n).TrimEnd();
                    lock (dbg) { if (dbg.Count < 400) dbg.Add(pid + ": " + s); }
                }
            }
        } catch (Exception e) { lock (dbg) dbg.Add("listener: " + e.Message); }
    }

    public static string Run() {
        var sb = new StringBuilder();
        var th = new Thread(Listen); th.IsBackground = true; th.Start();
        Thread.Sleep(300);
        Guid iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        IntPtr fac;
        int hr = CreateDXGIFactory1(ref iid, out fac);
        sb.AppendLine("CreateDXGIFactory1 hr=0x" + hr.ToString("x8") + " pid=" + System.Diagnostics.Process.GetCurrentProcess().Id);
        if (hr >= 0) {
            for (uint i = 0; i < 8; i++) {
                IntPtr ad;
                if (Vt<EnumAdapters1>(fac, 12)(fac, i, out ad) < 0) break;
                IntPtr desc = Marshal.AllocHGlobal(512);
                Vt<GetDesc>(ad, 8)(ad, desc);
                string name = Marshal.PtrToStringUni(desc);
                uint ven = (uint)Marshal.ReadInt32(desc, 256), dev = (uint)Marshal.ReadInt32(desc, 260);
                sb.AppendLine("adapter " + i + ": '" + name + "' ven=" + ven.ToString("x4") + " dev=" + dev.ToString("x4"));
                long luid = Marshal.ReadInt64(desc, 296);
                Marshal.FreeHGlobal(desc);
                if (ven == 0x1af4) { try { Kmt(sb, luid); } catch (Exception e) { sb.AppendLine("  kmt: " + e.Message); } }
                int[][] sets = {
                    new int[] { 0xb100, 0xb000, 0xa100, 0xa000, 0x9300, 0x9200, 0x9100 },
                };
                uint[] flags = { 0xa9 };
                foreach (uint f in flags) foreach (int[] lv in sets) {
                    IntPtr d, c; int got;
                    lock (dbg) dbg.Add("--- try adapter " + i + " flags=0x" + f.ToString("x") + " top=0x" + lv[0].ToString("x"));
                    int r = D3D11CreateDevice(ad, 0, IntPtr.Zero, f, lv, (uint)lv.Length, 7, out d, out got, out c);
                    sb.AppendLine("  flags=0x" + f.ToString("x") + " top=0x" + lv[0].ToString("x") + " -> hr=0x" + r.ToString("x8") + " level=0x" + got.ToString("x"));
                    if (c != IntPtr.Zero) Vt<Release>(c, 2)(c);
                    if (d != IntPtr.Zero) Vt<Release>(d, 2)(d);
                    Thread.Sleep(150);
                    if (r >= 0) goto next;
                }
                next:
                Vt<Release>(ad, 2)(ad);
            }
        }
        Thread.Sleep(800);
        stop = true;
        sb.AppendLine("--- debug output (" + dbg.Count + " lines)");
        lock (dbg) foreach (string s in dbg) sb.AppendLine(s);
        return sb.ToString();
    }
}
'@
$out = @("d3dtest $(Get-Date -Format s)")
try {
    Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
    $out += [D3DTest]::Run()
} catch { $out += "failed: $_" }
$out += '--- system log, last 20 min'
Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = (Get-Date).AddMinutes(-20); Level = 1, 2, 3 } -MaxEvents 200 -ErrorAction SilentlyContinue |
    Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 12 |
    ForEach-Object { $out += ("x{0}: {1}: {2}" -f $_.Count, $_.Name, (($_.Group[0].Message -replace "\s+", ' ') + '').Substring(0, [Math]::Min(300, (($_.Group[0].Message -replace "\s+", ' ') + '').Length))) }
$out += '--- display devices'
Get-PnpDevice -Class Display | ForEach-Object { $out += ("{0} {1} {2} problem={3}" -f $_.Status, $_.FriendlyName, $_.InstanceId, $_.Problem) }
$p = Join-Path $env:TEMP 'd3dtest.txt'
$out | Out-File -Encoding ascii $p
try { Invoke-WebRequest -UseBasicParsing -Method Put -Uri 'http://10.0.2.4/d3dtest.txt' -InFile $p | Out-Null } catch {}
