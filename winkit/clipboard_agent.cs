// WinKit clipboard helper: keeps Windows' clipboard in step with the iPhone's (docs/clipboard.md).
// clipboard_setup.ps1 compiles it with Add-Type (PowerShell 5.1, .NET Framework 4.8.1, C# 5) into
// %LOCALAPPDATA%\WinKit\WinKitClipboard.exe and starts it at every logon in the user's own session.
//
// Windows -> iPhone: a hidden message-only window gets WM_CLIPBOARDUPDATE (AddClipboardFormatListener, no
//   polling); the text is PUT to http://10.0.2.4/.henge/clipboard?agent=ID&n=K&force=1, K counting up
//   (force: a new copy here is news even when it is the text the iPhone sent last).
// iPhone -> Windows: GET /.henge/clipboard?since=N waits in the app (up to 25 s) until the iPhone's
//   clipboard changes; the text goes on Windows' clipboard, and only then is the next ?since= asked for,
//   which tells the app that Ctrl+V may follow.
// Loops: what this helper wrote itself is known by the clipboard's sequence number, and is not sent
//   back; nor is the same text put there again by another program right after (a clipboard manager).
//   Text that password managers mark as private (ExcludeClipboardContentFromMonitorProcessing,
//   CanIncludeInClipboardHistory = 0) is not sent at all. Text only, up to 1 MB of UTF-8.
using System;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace WinKit
{
    public static class ClipboardAgent
    {
        const string Url = "http://10.0.2.4/.henge/clipboard";
        const int MaxBytes = 1024 * 1024;
        const int WM_CLIPBOARDUPDATE = 0x031D;
        const int WM_APP_FROM_HOST = 0x8001;
        const uint CF_UNICODETEXT = 13;
        const uint GMEM_MOVEABLE = 0x0002;

        [DllImport("user32.dll", SetLastError = true)] static extern bool AddClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)] static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll", SetLastError = true)] static extern bool OpenClipboard(IntPtr hwnd);
        [DllImport("user32.dll")] static extern bool CloseClipboard();
        [DllImport("user32.dll")] static extern bool EmptyClipboard();
        [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
        [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr mem);
        [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
        [DllImport("user32.dll")] static extern int CountClipboardFormats();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr mem);
        [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr mem);
        [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr mem);
        [DllImport("kernel32.dll")] static extern UIntPtr GlobalSize(IntPtr mem);

        static MessageWindow window;
        static uint excludeFormat, historyFormat;

        // Touched only on the window's thread.
        static uint ownSequence;   // the clipboard's sequence number right after this helper wrote it
        static string ownText;     // what it wrote (newlines as \n), and when (Environment.TickCount)
        static int ownTick;
        static string queuedText;  // what was last queued for the app, and when: one copy can take
        static int queuedTick;     //   several WM_CLIPBOARDUPDATEs, which are sent once
        const int EchoMs = 1500;
        const int BurstMs = 1000;

        // From the receiving thread to the window's.
        static readonly object fromHostLock = new object();
        static string fromHost;
        static readonly AutoResetEvent fromHostApplied = new AutoResetEvent(false);

        // From the window's thread to the sending thread: the newest text wins.
        static readonly object toHostLock = new object();
        static string toHost;
        static readonly AutoResetEvent toHostReady = new AutoResetEvent(false);

        static readonly string agentId = Guid.NewGuid().ToString("N");
        static long sent;
        static readonly string logPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"WinKit\clipboard.log");
        static readonly object logLock = new object();

        [STAThread]
        public static int Main(string[] args)
        {
            bool first;
            using (Mutex single = new Mutex(true, @"Local\WinKitClipboardAgent", out first))
            {
                if (!first) return 0; // already running in this session
                ServicePointManager.Expect100Continue = false;
                ServicePointManager.DefaultConnectionLimit = 8;
                Application.ThreadException += delegate(object s, ThreadExceptionEventArgs e) { Log("ui: " + e.Exception.Message); };
                AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e) { Log("fatal: " + e.ExceptionObject); };
                excludeFormat = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
                historyFormat = RegisterClipboardFormat("CanIncludeInClipboardHistory");

                window = new MessageWindow();
                if (!AddClipboardFormatListener(window.Handle))
                {
                    Log("AddClipboardFormatListener failed: " + Marshal.GetLastWin32Error());
                    return 1; // the logon task starts it again
                }
                Log("started, agent " + agentId);
                StartThread(SendLoop, "send");
                StartThread(ReceiveLoop, "receive");
                Application.Run();
                RemoveClipboardFormatListener(window.Handle);
                GC.KeepAlive(single);
            }
            return 0;
        }

        static void StartThread(ThreadStart body, string name)
        {
            Thread t = new Thread(delegate()
            {
                for (;;)
                {
                    try { body(); }
                    catch (Exception e) { Log(name + ": " + e.Message); }
                    Thread.Sleep(3000);
                }
            });
            t.IsBackground = true;
            t.Name = name;
            t.Start();
        }

        sealed class MessageWindow : NativeWindow
        {
            public MessageWindow()
            {
                CreateParams cp = new CreateParams();
                cp.Parent = new IntPtr(-3); // HWND_MESSAGE: never shown, only messages
                CreateHandle(cp);
            }

            protected override void WndProc(ref Message m)
            {
                if (m.Msg == WM_CLIPBOARDUPDATE) { ClipboardChanged(); return; }
                if (m.Msg == WM_APP_FROM_HOST) { ApplyFromHost(); return; }
                base.WndProc(ref m);
            }
        }

        // ---- Windows -> iPhone

        static void ClipboardChanged()
        {
            if (GetClipboardSequenceNumber() == ownSequence) return; // this helper's own write
            string text = ReadClipboardText();
            if (text == null) return;
            text = text.Replace("\r\n", "\n");
            if (text.Length == 0) return;
            // Only a moment-long guard by text: the person may copy here, later, the very text the iPhone
            // sent or that went to the iPhone before, to have it there again.
            int now = Environment.TickCount;
            if (text == ownText && unchecked(now - ownTick) < EchoMs) return;     // put back by another program
            if (text == queuedText && unchecked(now - queuedTick) < BurstMs) return; // the same copy again
            if (Encoding.UTF8.GetByteCount(text) > MaxBytes) { Log("not sent: over 1 MB"); return; }
            queuedText = text;
            queuedTick = now;
            lock (toHostLock) toHost = text;
            toHostReady.Set();
        }

        // The text on the clipboard, or null: none, private, or the clipboard stayed busy.
        static string ReadClipboardText()
        {
            if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) return null;
            if (!Open()) return null;
            try
            {
                if (excludeFormat != 0 && IsClipboardFormatAvailable(excludeFormat)) return null;
                if (historyFormat != 0 && IsClipboardFormatAvailable(historyFormat))
                {
                    IntPtr h = GetClipboardData(historyFormat);
                    IntPtr p = h == IntPtr.Zero ? IntPtr.Zero : GlobalLock(h);
                    if (p != IntPtr.Zero)
                    {
                        int allowed = (ulong)GlobalSize(h) >= 4 ? Marshal.ReadInt32(p) : 1;
                        GlobalUnlock(h);
                        if (allowed == 0) return null;
                    }
                }
                IntPtr mem = GetClipboardData(CF_UNICODETEXT);
                if (mem == IntPtr.Zero) return null;
                IntPtr ptr = GlobalLock(mem);
                if (ptr == IntPtr.Zero) return null;
                try
                {
                    long chars = (long)(ulong)GlobalSize(mem) / 2;
                    if (chars > MaxBytes + 1) chars = MaxBytes + 1; // more cannot fit in 1 MB of UTF-8
                    string s = Marshal.PtrToStringUni(ptr, (int)chars);
                    int nul = s.IndexOf('\0');
                    return nul >= 0 ? s.Substring(0, nul) : s;
                }
                finally { GlobalUnlock(mem); }
            }
            finally { CloseClipboard(); }
        }

        // Another program may hold the clipboard for a moment.
        static bool Open()
        {
            for (int i = 0; i < 20; i++)
            {
                if (OpenClipboard(window.Handle)) return true;
                Thread.Sleep(25);
            }
            Log("clipboard busy");
            return false;
        }

        static void SendLoop()
        {
            for (;;)
            {
                toHostReady.WaitOne();
                string text;
                lock (toHostLock) { text = toHost; toHost = null; }
                if (text == null) continue;
                byte[] body = Encoding.UTF8.GetBytes(text);
                long n = Interlocked.Increment(ref sent);
                for (int attempt = 0; attempt < 3; attempt++)
                {
                    try
                    {
                        HttpWebRequest req = NewRequest(Url + "?agent=" + agentId + "&n=" + n + "&force=1", "PUT", 10000);
                        req.ContentType = "text/plain; charset=utf-8";
                        req.ContentLength = body.Length;
                        using (Stream s = req.GetRequestStream()) s.Write(body, 0, body.Length);
                        using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse()) { }
                        break;
                    }
                    catch (WebException e)
                    {
                        HttpWebResponse r = e.Response as HttpWebResponse;
                        if (r != null) { Log("send: HTTP " + (int)r.StatusCode); r.Close(); break; } // refused: no retry
                        Log("send: " + e.Message);
                        lock (toHostLock) if (toHost != null) break; // something newer is waiting
                        Thread.Sleep(1000 * (attempt + 1));
                    }
                }
            }
        }

        // ---- iPhone -> Windows

        static void ReceiveLoop()
        {
            ulong since = 0;
            bool first = true;
            for (;;)
            {
                string origin, text;
                ulong seq;
                int status;
                try
                {
                    status = Get(first ? Url : Url + "?since=" + since, out seq, out origin, out text);
                }
                catch (Exception e)
                {
                    Log("receive: " + e.Message);
                    Thread.Sleep(3000); // the app is not running, or Windows' network is not up yet
                    continue;
                }
                // At start the iPhone's last copy is taken too, but only into an empty clipboard (as at logon):
                // after a restart it must not replace what was copied in Windows meanwhile. After that, any
                // other number than asked for is news (a smaller one: the app started again).
                bool news = status == 200 && origin == "host" && text != null &&
                            (first ? CountClipboardFormats() == 0 : seq != since);
                first = false;
                if (news) Deliver(text);
                since = seq;
            }
        }

        static int Get(string url, out ulong seq, out string origin, out string text)
        {
            HttpWebRequest req = NewRequest(url, "GET", 40000);
            using (HttpWebResponse resp = (HttpWebResponse)req.GetResponse())
            {
                string h = resp.Headers["X-Henge-Seq"];
                if (h == null || !ulong.TryParse(h.Trim(), out seq)) throw new WebException("no X-Henge-Seq: not the app's server");
                origin = (resp.Headers["X-Henge-Origin"] ?? "").Trim();
                text = null;
                if ((int)resp.StatusCode == 200)
                {
                    using (Stream s = resp.GetResponseStream())
                    using (StreamReader r = new StreamReader(s, new UTF8Encoding(false)))
                        text = r.ReadToEnd();
                }
                return (int)resp.StatusCode;
            }
        }

        // Puts text on the clipboard on the window's thread, and waits until it is there.
        static void Deliver(string text)
        {
            lock (fromHostLock) fromHost = text;
            fromHostApplied.Reset();
            if (PostMessage(window.Handle, WM_APP_FROM_HOST, IntPtr.Zero, IntPtr.Zero)) fromHostApplied.WaitOne(5000);
        }

        static void ApplyFromHost()
        {
            string text;
            lock (fromHostLock) { text = fromHost; fromHost = null; }
            try
            {
                if (text != null) WriteClipboardText(text);
            }
            finally { fromHostApplied.Set(); }
        }

        static void WriteClipboardText(string text)
        {
            string windows = text.Replace("\r\n", "\n").Replace("\n", "\r\n");
            if (!Open()) return;
            try
            {
                EmptyClipboard();
                int bytes = (windows.Length + 1) * 2;
                IntPtr mem = GlobalAlloc(GMEM_MOVEABLE, new UIntPtr((uint)bytes));
                if (mem == IntPtr.Zero) return;
                IntPtr ptr = GlobalLock(mem);
                if (ptr == IntPtr.Zero) { GlobalFree(mem); return; }
                Marshal.Copy(windows.ToCharArray(), 0, ptr, windows.Length);
                Marshal.WriteInt16(ptr, windows.Length * 2, (short)0);
                GlobalUnlock(mem);
                if (SetClipboardData(CF_UNICODETEXT, mem) == IntPtr.Zero) GlobalFree(mem); // else the system owns it
            }
            finally
            {
                CloseClipboard();
                ownSequence = GetClipboardSequenceNumber();
                ownText = text.Replace("\r\n", "\n");
                ownTick = Environment.TickCount;
            }
        }

        // ---- plumbing

        static HttpWebRequest NewRequest(string url, string method, int timeoutMs)
        {
            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = method;
            req.Proxy = null; // straight to the app, never through a proxy or WPAD
            req.KeepAlive = false;
            req.Timeout = timeoutMs;
            req.ReadWriteTimeout = timeoutMs;
            req.UserAgent = "WinKitClipboard/1";
            return req;
        }

        static void Log(string line)
        {
            try
            {
                lock (logLock)
                {
                    FileInfo f = new FileInfo(logPath);
                    if (f.Exists && f.Length > 256 * 1024) File.Delete(logPath);
                    File.AppendAllText(logPath, DateTime.Now.ToString("s") + " " + line + "\r\n");
                }
            }
            catch { }
        }
    }
}
