# The clipboard shared with Windows

Text copied in Windows appears on the iPhone's clipboard, and text from the iPhone goes to Windows'
clipboard through the system paste button. Text only (UTF-8, up to 1 MB); pictures stay where they
were copied.

| Part | Where | What it does |
| --- | --- | --- |
| Host | `host/share.c` (`/.henge/clipboard` on `http://10.0.2.4`) | One clipboard slot with a sequence number and its origin; long poll; checks |
| Guest | `winkit/clipboard_agent.cs` → `WinKitClipboard.exe` | Watches Windows' clipboard, sends it, waits for the iPhone's |
| App | `ios/Sources/ClipboardSync.swift`, `ClipboardViews.swift`, the Clipboard category of `winios_bridge` | UIPasteboard, the paste button, settings, confirmations |

## The protocol

Everything goes through one slot in the app: the latest text, its sequence number (counts up from 1,
starts at 0 again when the app starts) and where it came from (`host`: the iPhone; `guest`: Windows).

- `GET /.henge/clipboard`: the slot now. `200` with the text, or `204` when it is empty. Either way
  `X-Henge-Seq: N` and `X-Henge-Origin: host|guest`.
- `GET /.henge/clipboard?since=N`: the same, but first waits up to 25 s (`&wait=S` for less) while the
  slot is still at `N`. The helper always has one of these waiting, so the iPhone's text reaches Windows
  at once without asking again and again. Any other `N` (one from before the app restarted, say) is
  answered at once.
- `PUT /.henge/clipboard?agent=ID&n=K`: what Windows copied. `ID` is the helper's name for itself (new
  each time it starts), `K` its own count of what it sent; a PUT that a newer one from the same helper
  overtook is dropped. `204` with the slot's `X-Henge-Seq` when taken, and also when nothing changed
  (empty, overtaken, or the text the slot holds already). `413` over 1 MB (the connection ends), `400`
  if it is not UTF-8 or has a NUL. A UTF-8 byte order mark is dropped.

Loops cannot form. The slot ignores text it holds already, so text that came from Windows and goes back
from the iPhone stops there (except when the person sends it with the paste button: then it is a change
on purpose, `hv_share_push_clipboard`, because Windows may have copied a picture since). The helper
remembers the clipboard sequence number (`GetClipboardSequenceNumber`) and the text it wrote itself, and
does not send those back.

Ctrl+V after sending waits until Windows really has the text: the helper asks for the next `?since=`
only once it has put the previous text on Windows' clipboard, so the app waits (up to 2.5 s) until the
helper's last `since` reaches what it sent (`hv_share_clipboard_agent_has`), and only then presses Ctrl+V
through the virtual USB keyboard.

The helper counts as running while its long poll waits, or when it was heard from in the last 40 s
(`hv_share_clipboard_agent_seen`).

`tests/test_share_clip.c` (part of `make test-core`, under ASan and UBSan) drives the server through its
socket: sequence numbers and origin, the long poll and its timeout, loops, overtaken PUTs, the size cap,
UTF-8, malformed requests, the app's listener and the helper's status.

## Windows: the helper

`WinKitClipboard.exe` is C# for .NET Framework 4.8.1, which Windows 11 has built in (natively on ARM64).
`winkit/clipboard_setup.ps1` builds it with PowerShell 5.1's `Add-Type` (C# 5, no SDK) into
`%LOCALAPPDATA%\WinKit`, so nothing compiled is shipped on the WINKIT disk.

- A hidden message-only window (`HWND_MESSAGE`) with `AddClipboardFormatListener`: Windows tells it of
  every change, nothing polls. It reads `CF_UNICODETEXT`, turns CRLF into LF and sends the text on a
  thread of its own (the newest wins if the app is slow).
- What password managers mark as private is not sent: `ExcludeClipboardContentFromMonitorProcessing`,
  or `CanIncludeInClipboardHistory` = 0.
- From the iPhone: the text goes on the clipboard (LF as CRLF) with `SetClipboardData` on the window's
  thread. At start the iPhone's last text is taken only into an empty clipboard (as at logon), so a
  restarted helper does not replace what was copied in Windows meanwhile.
- It runs in the user's own session, not elevated, through the scheduled task **WinKit Clipboard**: at
  logon, and every 5 minutes after that (a running helper is left alone, a stopped one is started again).
  A mutex keeps it to one per session. If a policy refuses the task, a Startup folder shortcut is used.
- Its log: `%LOCALAPPDATA%\WinKit\clipboard.log`.

Install: `START.bat` does it; `CLIPBOARD.bat` on the WINKIT drive does only this, without administrator
rights, and can be run again. `CLIPBOARD.bat remove` or `uninstall_clipboard.ps1` take it away.

## iPhone: the app

**Windows → iPhone.** Writing `UIPasteboard` never asks anything. When Windows copies, the share server
calls the app (`hv_share_set_clipboard_listener` → `WinIOSGuestClipboardDidChangeNotification`) and the
text is put on the clipboard while the app is active; otherwise it waits (the newest only) until the app
is active again. A short "Copied from Windows" shows at the bottom. Settings › Clipboard › "Windows →
iPhone automatically" (on by default) switches it off.

**iPhone → Windows.** An app that reads the clipboard by itself gets iOS's "Allow Paste" question each
time, unless the person chose Allow for it. So:

- `ClipboardButton` is the system paste button (`PasteButton`, i.e. `UIPasteControl`). Tapping it is the
  person's own paste and is never asked about. It sits in the floating toolbar and in Settings ›
  Clipboard; any view can mount it.
- Sending by itself when the app becomes active is off by default. It runs only when it is switched on
  AND the app found the permission to be Allow. iOS has no call that tells the permission, so "Check" (and
  switching the option on) reads the clipboard once, at the person's request: a read that waits more than
  0.35 s waited for iOS's question (Ask), one that gives nothing at once is Deny, otherwise Allow. Reading
  text this app wrote itself never asks, so that check needs text copied in another app. Before every
  automatic read, `UIPasteboard.changeCount` and `hasStrings` (neither of which asks) skip a clipboard
  with nothing new or no text. If iOS asks after all (the setting was changed), automatic sending stops
  until checked again.
- To allow it: iOS Settings › Apple VM › Paste from Other Apps › Allow. The item appears once the app has
  read the clipboard at least once.
- "Paste into Windows after sending" presses Ctrl+V once Windows has the text (see above).
- "Sent to Windows" confirms; when the helper is not running the app says so (the text still waits in
  the slot and the helper takes it when it starts into an empty clipboard).

`ClipboardSettingsSection` (the switches, the paste permission, the helper's status) is mounted in the
settings sheet; `.clipboardSync()` starts the sync and shows the confirmations.

## Only on the device

The host side is tested on the Mac; these need Windows and an iPhone:

- the helper builds with `Add-Type` on Windows 11 ARM64 and the task starts it at logon;
- copying in Windows (Notepad, Edge, Explorer file names) reaches the iPhone, and back;
- the system paste button in the toolbar takes taps (iOS refuses taps on a paste button it finds hard to
  see) and never asks;
- the permission check on "Ask", "Deny" and "Allow", and that automatic sending never asks;
- Ctrl+V after sending pastes the new text, not the old one;
- text copied from KeePass or another password manager is not sent;
- the helper is started again within 5 minutes after it is ended in Task Manager.
