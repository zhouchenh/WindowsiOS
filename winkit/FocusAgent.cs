// SPDX-License-Identifier: GPL-2.0-or-later
// WinKit focus agent: tells the app on the phone where the keyboard focus and the text caret are, so the
// on-screen keyboard comes up in text boxes, goes away elsewhere, and the picture moves the caret into view.
// It also types text the iOS keyboard sends that a USB keyboard cannot (Chinese, accents, emoji).
//
// Compiled at logon by %LOCALAPPDATA%\WinKit\focus.ps1 (written by cli_setup.ps1) with Add-Type, so it
// is C# 5 for the .NET Framework compiler: no string interpolation, no ?., no expression bodies.
// All event callbacks are C#: WinEvent callbacks arrive on threads without a PowerShell runspace.
//
// What it sends: PUT http://10.0.2.4/.henge/focus with one JSON object, only when something changed:
//   {"seq":12,"event":"focus|caret|foreground|lang|typefail|hello","kind":"text|secure|none",
//    "elem":[x,y,w,h],"caret":[x,y,w,h],"exe":"notepad.exe","lang":"zh-CN","fb":[w,h],
//    "secureDesktop":false,"source":"uia|class|caret"}
// Rectangles are in framebuffer (physical screen) pixels; [] when unknown.
// The reply, and the reply to the long poll PUT .../focus?wait=20, is text to type (UTF-8), or 204.
//
// Limits: windows of elevated programs (administrator consoles, regedit) and the secure desktop (UAC,
// Ctrl+Alt+Del, the lock screen) are out of reach of a normal user's program: there the app falls back to
// the tap point and does not raise the keyboard by itself, and typed text that cannot be delivered is
// reported back ("typefail").
//
// UI Automation is used once per focus change, only to classify the focused element (text, password or
// neither). A file named focus_nouia in %LOCALAPPDATA%\WinKit turns that off (class names and the caret
// are used instead), e.g. if Edge or VS Code get slow.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

namespace WinKit
{
    public static class FocusAgent
    {
        const string Url = "http://10.0.2.4/.henge/focus";

        // ---- Win32 ----
        delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);

        [DllImport("user32.dll")]
        static extern IntPtr SetWinEventHook(uint evMin, uint evMax, IntPtr hmod, WinEventProc proc, uint pid, uint tid, uint flags);
        [DllImport("user32.dll")]
        static extern bool UnhookWinEvent(IntPtr hook);

        [StructLayout(LayoutKind.Sequential)]
        struct POINT { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential)]
        struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }

        [DllImport("user32.dll")]
        static extern int GetMessage(out MSG msg, IntPtr hwnd, uint min, uint max);
        [DllImport("user32.dll")]
        static extern bool TranslateMessage(ref MSG msg);
        [DllImport("user32.dll")]
        static extern IntPtr DispatchMessage(ref MSG msg);

        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        struct GUITHREADINFO
        {
            public uint cbSize;
            public uint flags;
            public IntPtr hwndActive;
            public IntPtr hwndFocus;
            public IntPtr hwndCapture;
            public IntPtr hwndMenuOwner;
            public IntPtr hwndMoveSize;
            public IntPtr hwndCaret;
            public RECT rcCaret;
        }

        [DllImport("user32.dll")]
        static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
        [DllImport("user32.dll")]
        static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT r, uint n);
        [DllImport("user32.dll")]
        static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")]
        static extern IntPtr GetKeyboardLayout(uint tid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int GetClassName(IntPtr hwnd, StringBuilder sb, int n);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
        static extern int GetWindowLong(IntPtr hwnd, int index);
        [DllImport("user32.dll")]
        static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
        [DllImport("user32.dll")]
        static extern int GetSystemMetrics(int i);
        [DllImport("user32.dll")]
        static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);
        [DllImport("user32.dll")]
        static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll")]
        static extern bool CloseDesktop(IntPtr h);

        [StructLayout(LayoutKind.Sequential)]
        struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

        [StructLayout(LayoutKind.Sequential)]
        struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

        // The union is as large as its largest member (MOUSEINPUT), so INPUT has the size SendInput expects.
        [StructLayout(LayoutKind.Explicit)]
        struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }

        [StructLayout(LayoutKind.Sequential)]
        struct INPUT { public uint type; public InputUnion u; }

        [DllImport("user32.dll", SetLastError = true)]
        static extern uint SendInput(uint n, INPUT[] inputs, int size);

        [DllImport("oleacc.dll")]
        static extern int AccessibleObjectFromWindow(IntPtr hwnd, uint id, ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object obj);

        const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
        const uint EVENT_OBJECT_FOCUS = 0x8005;
        const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;
        const uint WINEVENT_OUTOFCONTEXT = 0x0000;
        const uint WINEVENT_SKIPOWNPROCESS = 0x0002;
        const int OBJID_CARET = -8;
        const int GWL_STYLE = -16;
        const int ES_PASSWORD = 0x0020;
        const int ES_READONLY = 0x0800;
        const uint KEYEVENTF_KEYUP = 0x0002;
        const uint KEYEVENTF_UNICODE = 0x0004;

        // ---- state ----
        static readonly object Gate = new object();
        static bool pendingFocus, pendingForeground, pendingCaret;
        static readonly AutoResetEvent Wake = new AutoResetEvent(false);
        static WinEventProc hookProc; // kept alive: the hooks call it
        static string dir;
        static string logPath;
        static long seq;
        static string lastSent = "";
        static string curKind = "none";
        static string curExe = "";
        static string curLang = "";
        static int[] curElem = new int[0];
        static int[] curCaret = new int[0];
        static string curSource = "";
        static bool curSecureDesktop;
        static DateTime lastCaretSend = DateTime.MinValue;
        static int failures;
        static readonly object TypeGate = new object();

        static void Log(string s)
        {
            try
            {
                if (logPath == null) return;
                FileInfo fi = new FileInfo(logPath);
                if (fi.Exists && fi.Length > 256 * 1024) File.Delete(logPath);
                File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + s + "\r\n");
            }
            catch { }
        }

        static void DpiAware()
        {
            try { SetThreadDpiAwarenessContext(new IntPtr(-4)); } // PER_MONITOR_AWARE_V2: rectangles in screen pixels
            catch (EntryPointNotFoundException) { }
        }

        // Blocks until the helper is removed (agent.ps1 gone) or another copy is already running.
        public static void Run(string winkitDir)
        {
            dir = winkitDir;
            logPath = Path.Combine(dir, "focus.log");
            bool created;
            Mutex single = new Mutex(true, "Local\\WinKitFocusAgent", out created);
            if (!created)
            {
                Log("another focus agent is running: this one stops");
                return;
            }
            ServicePointManager.DefaultConnectionLimit = 8;
            ServicePointManager.Expect100Continue = false;
            bool useUia = !File.Exists(Path.Combine(dir, "focus_nouia"));
            Log("focus agent started (UI Automation " + (useUia ? "on" : "off") + ")");
            if (useUia) Uia.Start();

            Thread hooks = new Thread(HookThread);
            hooks.IsBackground = true;
            hooks.Name = "winkit-focus-hooks";
            hooks.Start();
            Thread poll = new Thread(PollThread);
            poll.IsBackground = true;
            poll.Name = "winkit-focus-text";
            poll.Start();

            Worker(useUia);
            GC.KeepAlive(single);
        }

        static void HookThread()
        {
            DpiAware();
            hookProc = new WinEventProc(OnWinEvent);
            uint fl = WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS;
            IntPtr h1 = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, hookProc, 0, 0, fl);
            IntPtr h2 = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, IntPtr.Zero, hookProc, 0, 0, fl);
            IntPtr h3 = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, IntPtr.Zero, hookProc, 0, 0, fl);
            Log("hooks: foreground=" + (h1 != IntPtr.Zero) + " focus=" + (h2 != IntPtr.Zero) + " caret=" + (h3 != IntPtr.Zero));
            MSG msg;
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
        }

        // Runs on the hook thread for every event: only notes what happened, the worker does the rest.
        static void OnWinEvent(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (ev == EVENT_OBJECT_LOCATIONCHANGE)
            {
                if (idObject != OBJID_CARET) return;
                lock (Gate) pendingCaret = true;
            }
            else if (ev == EVENT_OBJECT_FOCUS)
            {
                lock (Gate) pendingFocus = true;
            }
            else if (ev == EVENT_SYSTEM_FOREGROUND)
            {
                lock (Gate) pendingForeground = true;
            }
            Wake.Set();
        }

        static void Worker(bool useUia)
        {
            DpiAware();
            Send("hello", true);
            DateTime lastSlow = DateTime.MinValue;
            for (;;)
            {
                Wake.WaitOne(1000);
                bool f, g, c;
                lock (Gate) { f = pendingFocus; g = pendingForeground; c = pendingCaret; }
                if (f || g)
                {
                    Thread.Sleep(60); // focus changes come in bursts (menus, dialogs): take the last one
                    lock (Gate) { pendingFocus = false; pendingForeground = false; pendingCaret = false; }
                    Refresh(useUia, true);
                    Send(g && !f ? "foreground" : "focus", true);
                }
                else if (c)
                {
                    double since = (DateTime.UtcNow - lastCaretSend).TotalMilliseconds;
                    if (since < 80) Thread.Sleep(80 - (int)since); // at most ~12 caret reports a second
                    lock (Gate) pendingCaret = false;
                    Refresh(false, false);
                    if (Send("caret", false)) lastCaretSend = DateTime.UtcNow;
                }
                if ((DateTime.UtcNow - lastSlow).TotalMilliseconds >= 1000)
                {
                    lastSlow = DateTime.UtcNow;
                    // the input language (Win+Space) and the secure desktop raise no event we hook
                    string lang = curLang;
                    bool sd = curSecureDesktop;
                    curLang = InputLanguage();
                    curSecureDesktop = SecureDesktop();
                    if (lang != curLang || sd != curSecureDesktop)
                    {
                        if (curSecureDesktop) { curKind = "none"; curCaret = new int[0]; }
                        Send(lang != curLang ? "lang" : "focus", false);
                    }
                    if (!File.Exists(Path.Combine(dir, "agent.ps1")))
                    {
                        Log("the WinKit helper was removed: the focus agent stops");
                        return;
                    }
                }
            }
        }

        // Reads the focus, the caret and the foreground program. classify: also asks UI Automation.
        static void Refresh(bool useUia, bool classify)
        {
            IntPtr fg = GetForegroundWindow();
            uint pid;
            uint tid = GetWindowThreadProcessId(fg, out pid);
            curExe = ExeName(pid);
            curLang = InputLanguage();
            curSecureDesktop = SecureDesktop();

            GUITHREADINFO gi = new GUITHREADINFO();
            gi.cbSize = (uint)Marshal.SizeOf(typeof(GUITHREADINFO));
            bool haveGui = tid != 0 && GetGUIThreadInfo(tid, ref gi);
            int[] caret = CaretRect(haveGui, gi);
            curCaret = caret;
            if (!classify) return;

            string kind = null;
            int[] elem = new int[0];
            string source = "";
            if (useUia)
            {
                Uia.Result r = Uia.Classify(600);
                if (r != null)
                {
                    kind = r.Kind;
                    elem = r.Rect;
                    source = "uia";
                }
            }
            if (kind == null && haveGui && gi.hwndFocus != IntPtr.Zero)
            {
                kind = ClassifyByClass(gi.hwndFocus);
                if (kind != null) source = "class";
                RECT wr;
                if (GetWindowRect(gi.hwndFocus, out wr)) elem = new int[] { wr.Left, wr.Top, wr.Right - wr.Left, wr.Bottom - wr.Top };
            }
            if (kind == null)
            {
                kind = caret.Length == 4 ? "text" : "none"; // a blinking caret means a place to type
                source = "caret";
            }
            if (curSecureDesktop) kind = "none";
            curKind = kind;
            curElem = elem;
            curSource = source;
        }

        static int[] CaretRect(bool haveGui, GUITHREADINFO gi)
        {
            if (haveGui && gi.hwndCaret != IntPtr.Zero && gi.rcCaret.Bottom > gi.rcCaret.Top)
            {
                RECT r = gi.rcCaret;
                MapWindowPoints(gi.hwndCaret, IntPtr.Zero, ref r, 2);
                return new int[] { r.Left, r.Top, Math.Max(1, r.Right - r.Left), r.Bottom - r.Top };
            }
            // Chromium, Office and others draw their own caret and report it to accessibility clients only.
            IntPtr hwnd = haveGui && gi.hwndFocus != IntPtr.Zero ? gi.hwndFocus : GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return new int[0];
            try
            {
                Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71"); // IAccessible
                object o;
                if (AccessibleObjectFromWindow(hwnd, unchecked((uint)OBJID_CARET), ref iid, out o) == 0 && o != null)
                {
                    Accessibility.IAccessible acc = o as Accessibility.IAccessible;
                    if (acc != null)
                    {
                        int x, y, w, h;
                        acc.accLocation(out x, out y, out w, out h, 0);
                        if (h > 0) return new int[] { x, y, Math.Max(1, w), h };
                    }
                }
            }
            catch { }
            return new int[0];
        }

        static string ClassifyByClass(IntPtr hwnd)
        {
            StringBuilder sb = new StringBuilder(256);
            GetClassName(hwnd, sb, sb.Capacity);
            string cls = sb.ToString();
            int style = GetWindowLong(hwnd, GWL_STYLE);
            if (cls == "Edit" || cls.StartsWith("RichEdit", StringComparison.OrdinalIgnoreCase) || cls == "RICHEDIT50W")
            {
                if ((style & ES_PASSWORD) != 0) return "secure";
                return (style & ES_READONLY) != 0 ? "none" : "text";
            }
            if (cls == "ConsoleWindowClass" || cls == "CASCADIA_HOSTING_WINDOW_CLASS" || cls == "Scintilla" || cls == "_WwG")
                return "text";
            return null;
        }

        static uint exePid;
        static string exeName = "";

        static string ExeName(uint pid)
        {
            if (pid == 0) return "";
            if (pid == exePid) return exeName; // caret reports come often: no process lookup each time
            exePid = pid;
            try
            {
                using (Process p = Process.GetProcessById((int)pid)) exeName = p.ProcessName + ".exe";
            }
            catch { exeName = ""; }
            return exeName;
        }

        static string InputLanguage()
        {
            try
            {
                IntPtr fg = GetForegroundWindow();
                uint pid;
                uint tid = GetWindowThreadProcessId(fg, out pid);
                int lcid = (int)((long)GetKeyboardLayout(tid) & 0xFFFF);
                if (lcid == 0) return curLang;
                return CultureInfo.GetCultureInfo(lcid).Name;
            }
            catch { return curLang; }
        }

        static bool SecureDesktop()
        {
            IntPtr d = OpenInputDesktop(0, false, 0x0001); // DESKTOP_READOBJECTS: refused on the secure desktop
            if (d == IntPtr.Zero) return true;
            CloseDesktop(d);
            return false;
        }

        // ---- the app ----

        static string Json(string ev)
        {
            StringBuilder sb = new StringBuilder(256);
            sb.Append("{\"seq\":").Append(seq.ToString(CultureInfo.InvariantCulture));
            sb.Append(",\"event\":\"").Append(Esc(ev)).Append('"');
            sb.Append(",\"kind\":\"").Append(Esc(curKind)).Append('"');
            sb.Append(",\"elem\":").Append(Arr(curElem));
            sb.Append(",\"caret\":").Append(Arr(curCaret));
            sb.Append(",\"exe\":\"").Append(Esc(curExe)).Append('"');
            sb.Append(",\"lang\":\"").Append(Esc(curLang)).Append('"');
            sb.Append(",\"fb\":[").Append(GetSystemMetrics(0).ToString(CultureInfo.InvariantCulture)).Append(',')
              .Append(GetSystemMetrics(1).ToString(CultureInfo.InvariantCulture)).Append(']');
            sb.Append(",\"secureDesktop\":").Append(curSecureDesktop ? "true" : "false");
            sb.Append(",\"source\":\"").Append(Esc(curSource)).Append('"');
            sb.Append('}');
            return sb.ToString();
        }

        static string Arr(int[] a)
        {
            StringBuilder sb = new StringBuilder("[");
            for (int i = 0; i < a.Length; i++)
            {
                if (i > 0) sb.Append(',');
                sb.Append(a[i].ToString(CultureInfo.InvariantCulture));
            }
            return sb.Append(']').ToString();
        }

        static string Esc(string s)
        {
            if (s == null) return "";
            StringBuilder sb = new StringBuilder(s.Length + 8);
            foreach (char ch in s)
            {
                if (ch == '"' || ch == '\\') sb.Append('\\').Append(ch);
                else if (ch < 0x20 || ch > 0x7e) sb.Append("\\u").Append(((int)ch).ToString("x4"));
                else sb.Append(ch);
            }
            return sb.ToString();
        }

        // Sends the state when it differs from the last one sent (always, when force). True if sent.
        static bool Send(string ev, bool force)
        {
            seq++;
            string body = Json(ev);
            string cmp = body.Substring(body.IndexOf(",\"kind\"", StringComparison.Ordinal));
            if (!force && cmp == lastSent) return false;
            lastSent = cmp;
            string reply = Put(Url, body, 3000);
            if (!string.IsNullOrEmpty(reply)) TypeText(reply);
            return true;
        }

        static string Put(string url, string body, int timeoutMs)
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = "PUT";
                req.Proxy = null; // no proxy discovery (WPAD) in front of every request
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.ContentType = "application/json";
                req.KeepAlive = true;
                byte[] b = Encoding.UTF8.GetBytes(body);
                req.ContentLength = b.Length;
                using (Stream s = req.GetRequestStream()) s.Write(b, 0, b.Length);
                using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
                {
                    failures = 0;
                    if (resp.StatusCode != HttpStatusCode.OK) return null;
                    using (StreamReader rd = new StreamReader(resp.GetResponseStream(), Encoding.UTF8)) return rd.ReadToEnd();
                }
            }
            catch (Exception e)
            {
                if (failures++ % 20 == 0) Log("PUT " + url + ": " + e.Message);
                return null;
            }
        }

        // Waits for text from the iOS keyboard and types it.
        static void PollThread()
        {
            DpiAware();
            for (;;)
            {
                string reply = Put(Url + "?wait=20", "{}", 30000);
                if (reply == null && failures > 0)
                {
                    Thread.Sleep(failures > 10 ? 15000 : 2000); // the app is not there (or too old for this)
                    continue;
                }
                if (!string.IsNullOrEmpty(reply)) TypeText(reply);
            }
        }

        static INPUT Key(ushort vk, ushort scan, uint flags)
        {
            INPUT i = new INPUT();
            i.type = 1; // INPUT_KEYBOARD
            i.u.ki.wVk = vk;
            i.u.ki.wScan = scan;
            i.u.ki.dwFlags = flags;
            return i;
        }

        // Types s where the keyboard focus is: characters as Unicode key events (VK_PACKET; surrogate pairs as
        // two), \b as Backspace, \n as Enter, \t as Tab. Reports text that Windows did not take.
        static void TypeText(string s)
        {
            List<INPUT> list = new List<INPUT>(s.Length * 2);
            for (int i = 0; i < s.Length; i++)
            {
                char ch = s[i];
                ushort vk = 0;
                if (ch == '\b') vk = 0x08;
                else if (ch == '\n') vk = 0x0D;
                else if (ch == '\r') { if (i + 1 < s.Length && s[i + 1] == '\n') continue; vk = 0x0D; }
                else if (ch == '\t') vk = 0x09;
                else if (ch < 0x20) continue;
                if (vk != 0)
                {
                    list.Add(Key(vk, 0, 0));
                    list.Add(Key(vk, 0, KEYEVENTF_KEYUP));
                }
                else
                {
                    list.Add(Key(0, ch, KEYEVENTF_UNICODE));
                    list.Add(Key(0, ch, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                }
            }
            if (list.Count == 0) return;
            uint sent = 0;
            lock (TypeGate)
            {
                INPUT[] all = list.ToArray();
                int size = Marshal.SizeOf(typeof(INPUT));
                for (int at = 0; at < all.Length; at += 64)
                {
                    int n = Math.Min(64, all.Length - at);
                    INPUT[] part = new INPUT[n];
                    Array.Copy(all, at, part, 0, n);
                    uint got = SendInput((uint)n, part, size);
                    sent += got;
                    if (got < n) break;
                }
            }
            if (sent < list.Count)
            {
                Log("typing: Windows took " + sent + " of " + list.Count + " key events (error " + Marshal.GetLastWin32Error() + ")");
                Send("typefail", true);
            }
        }

        // ---- UI Automation, on its own thread: a call into a hung program must not stop the agent ----
        static class Uia
        {
            public class Result
            {
                public string Kind;
                public int[] Rect;
            }

            static readonly AutoResetEvent Ask = new AutoResetEvent(false);
            static readonly object Lock = new object();
            static Result answer;
            static bool answered;
            static bool busy;
            static int errors;

            public static void Start()
            {
                Thread t = new Thread(Loop);
                t.IsBackground = true;
                t.Name = "winkit-focus-uia";
                t.SetApartmentState(ApartmentState.STA);
                t.Start();
            }

            // The focused element's kind, or null if UI Automation did not answer within timeoutMs.
            public static Result Classify(int timeoutMs)
            {
                lock (Lock)
                {
                    if (busy) return null; // still stuck in the last call
                    busy = true;
                    answered = false;
                    answer = null;
                }
                Ask.Set();
                DateTime until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
                lock (Lock)
                {
                    while (!answered)
                    {
                        int left = (int)(until - DateTime.UtcNow).TotalMilliseconds;
                        if (left <= 0) return null;
                        Monitor.Wait(Lock, left);
                    }
                    return answer;
                }
            }

            static void Loop()
            {
                DpiAware();
                for (;;)
                {
                    Ask.WaitOne();
                    Result r = null;
                    try { r = ClassifyFocused(); }
                    catch (Exception e)
                    {
                        // e.g. an administrator window: out of reach, the caller falls back
                        if (errors++ < 20) Log("UI Automation: " + e.GetType().Name + ": " + e.Message);
                    }
                    lock (Lock)
                    {
                        answer = r;
                        answered = true;
                        busy = false;
                        Monitor.PulseAll(Lock);
                    }
                }
            }

            static Result ClassifyFocused()
            {
                AutomationElement el = AutomationElement.FocusedElement;
                if (el == null) return null;
                AutomationElement.AutomationElementInformation cur = el.Current;
                Result r = new Result();
                System.Windows.Rect b = cur.BoundingRectangle;
                r.Rect = b.IsEmpty ? new int[0] : new int[] { (int)b.X, (int)b.Y, (int)b.Width, (int)b.Height };
                if (cur.IsPassword) { r.Kind = "secure"; return r; }
                object vp, tp;
                bool hasValue = el.TryGetCurrentPattern(ValuePattern.Pattern, out vp);
                bool readOnly = hasValue && ((ValuePattern)vp).Current.IsReadOnly;
                bool hasText = el.TryGetCurrentPattern(TextPattern.Pattern, out tp);
                ControlType ct = cur.ControlType;
                bool text = false;
                if (cur.IsEnabled)
                {
                    if (ct == ControlType.Edit) text = !readOnly;
                    else if (ct == ControlType.Document) text = hasValue && !readOnly;
                    else text = hasText && hasValue && !readOnly && cur.IsKeyboardFocusable;
                }
                r.Kind = text ? "text" : "none";
                return r;
            }
        }
    }
}
