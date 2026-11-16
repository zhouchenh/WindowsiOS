# Sign-in links in Safari: the OAuth bridge

Desktop apps in Windows (IDEs, CLIs, chat clients) sign you in by opening a web page in the default
browser. When you finish signing in, the page sends your browser to `http://localhost:<port>/...`,
where the app is waiting. Inside the VM, the Windows browser (Edge) has none of your accounts,
passwords or passkeys. The bridge sends those pages to **Safari on the iPhone** instead, in a
sheet over the VM, and gets the `localhost` redirect back into Windows. So "Sign in with Google"
uses the Google session, saved passwords, passkeys and Face ID you already have on the iPhone.

The bridge has two halves:

| Half | Where | What it does |
| --- | --- | --- |
| Host | `host/share.c`, `host/net_slirp.c`, `ios/Sources` | Serves `/.henge/open-url`, `/.henge/expose-port` and `/.henge/oauth-done` on `http://10.0.2.4`, forwards ports and shows the Safari sheet (`SFSafariViewController`) |
| Guest | `tools/winios_browser_arm64.c` → `WinIOSBrowser.exe` | A 10 KB native ARM64 Windows program, registered as a browser. Windows hands it every link it opens |

## Setting it up

Build (on the Mac):

```sh
make guest-tools   # build/guest/WinIOSBrowser.exe (Homebrew llvm + lld, no Windows SDK)
make winkit-img    # dist/WinKit/drivers.img: winkit/ plus WinIOSBrowser.exe (needs mtools)
scripts/embed_gpu3d.sh <WindowsiOS.app> <UTM.app/Frameworks> ...   # puts the disk into the app as winkit.img
```

In Windows, the WINKIT drive then contains `WinIOSBrowser.exe`. Install it in either of two ways:

- **`START.bat`** (the WinKit setup): step 5/5 installs it.
- **`SAFARI-SIGNIN.bat`**, on the WINKIT drive or in `C:\WinKit`: does only this step. Use it on a
  Windows that ran an older WinKit, or to choose the browser again later.

Both run `oauth_setup.ps1` as administrator. It is safe to run again. It:

1. copies `WinIOSBrowser.exe` to `C:\Program Files\WinIOS\`;
2. registers it as a browser called **WinIOS Browser**:
   - `HKLM\SOFTWARE\Clients\StartMenuInternet\WinIOSBrowser` with `Capabilities`:
     `URLAssociations` http/https and `FileAssociations` .htm/.html, all mapped to `WinIOSHTML`;
   - `HKLM\SOFTWARE\RegisteredApplications\WinIOSBrowser`;
   - the ProgID `HKLM\SOFTWARE\Classes\WinIOSHTML`, with
     `shell\open\command` = `"C:\Program Files\WinIOS\WinIOSBrowser.exe" "%1"`;
   - `OpenWithProgids` entries for .htm and .html;
3. adds an inbound firewall rule `WinIOSBrowser-Relay` (TCP, that program, local subnet only), so the
   sign-in callback relay (below) can accept the redirect without a firewall prompt;
4. opens **Settings → Apps → Default apps → WinIOS Browser**
   (`ms-settings:defaultapps?registeredAppMachine=WinIOSBrowser`). There you click **Set default**.

Step 4 is manual on purpose. Windows 11's `UCPD.sys` driver blocks programs from changing the
default browser (the `UserChoice` keys for http/https), so the script cannot do it for you. If the
script finds that WinIOS Browser is already the default, it skips Settings.

To remove it, run `C:\WinKit\uninstall_oauth.ps1` as administrator. It deletes the program, the
registry entries and the firewall rule. Windows then goes back to Edge and may ask once which app to
use.

## What happens when you sign in

```
Windows app          WinIOSBrowser.exe                 app on the iPhone (host)            Safari sheet
-----------          -----------------                 ------------------------            ------------
listens on
localhost:P  ──opens https://accounts…?redirect_uri=http%3A%2F%2Flocalhost%3AP%2F…──▶
                     1. finds P in the URL (also after one or two rounds of URL-decoding)
                        starts "WinIOSBrowser.exe --relay P": listens on 10.0.2.15:P
                        PUT /.henge/expose-port  P ──▶ forwards 127.0.0.1:P and [::1]:P
                                                       to 10.0.2.15:P (libslirp)
                     2. PUT /.henge/open-url  URL ──▶ 204: shows URL ───────────────────▶ you sign in
                                                                                         (passkey, Face ID…)
                                                       127.0.0.1:P ◀── redirect to localhost:P/…?code=…
                     relay 10.0.2.15:P ◀────────────── forwarded into the guest
localhost:P ◀──────── relay → 127.0.0.1:P (or [::1]:P)
answers 200/302 ────▶ relay sees it: PUT /.henge/oauth-done ──▶ closes the sheet (haptic)
```

In detail:

- **Port discovery.** `WinIOSBrowser.exe` looks for `localhost:<port>` and `127.0.0.1:<port>` in
  the URL, once as given and again after one and two rounds of URL-decoding, since `redirect_uri`
  is usually encoded. Ports 1024–65535 count, up to 8 per link. The host does the same scan on the
  URL it receives (`auto_forward_localhost_ports` in `host/share.c`).
- **The relay** is a second copy of the program (`--relay <port>`, no window). It listens on
  `10.0.2.15:<port>`, the guest's own address. The app usually listens only on loopback, so the
  relay connects each incoming connection to `127.0.0.1:<port>`, falling back to `[::1]:<port>`
  (Go and Node often bind `localhost` to IPv6 only). It stops 4 s after a finished sign-in, or after
  30 minutes without a connection.
- **Port forward.** `PUT /.henge/expose-port` makes `host/net_slirp.c` add a libslirp host forward
  `127.0.0.1:<port> → 10.0.2.15:<port>`, plus an IPv6 bridge for `[::1]:<port>`. Safari's redirect
  to `localhost:<port>` on the iPhone therefore reaches the relay.
- **Done.** The relay watches the first request line for `/auth`, `/oauth`, `callback` or `code=`.
  When the app answers it with 200, 301 or 302, the relay sends `PUT /.henge/oauth-done`. The app
  closes the Safari sheet with a success haptic (`VMViewModel.startOAuthPoller`).
- **Log.** `%TEMP%\winios_browser.log` in Windows lists every call, the ports it found and the
  open-url status.

## Safari or Edge: the toggle

In the app, **Settings → "Open sign-in links from Windows in Safari"** chooses where links go. The
setting is stored as `winios.safariOAuthV2` and is on by default.

- **On**: `/.henge/open-url` answers `204` and the link opens in the Safari sheet.
- **Off**: `/.henge/open-url` answers `409 Conflict`, and `WinIOSBrowser.exe` starts Microsoft Edge
  (`msedge.exe`) in Windows with the same URL. The port forward and the relay are set up anyway,
  so a sign-in finished in Edge works as usual. If the link looked like a sign-in (`oauth` or
  `redirect_uri=` in it), the host remembers it for 5 minutes. Turning the toggle on within that
  time opens that link in Safari at once (`hv_share_set_url_handler_enabled`).
- If the app cannot be reached (no answer from `10.0.2.4` within 1.5 s), `WinIOSBrowser.exe` also
  falls back to Edge. Anything that is not an `http(s)` URL (a local file, for example) always
  goes to Edge.

With WinIOS Browser as the default, **every** link that Windows opens goes through the bridge, not
only sign-ins. While the toggle is on, ordinary links open in the Safari sheet too. Turn the toggle
off if you would rather browse in Edge inside Windows and use Safari only now and then. Links
clicked inside Edge itself stay in Edge.

On the Mac (`build/winvm`), the host side is off unless `HV_OAUTH_BRIDGE=1` is set. There is no
Safari sheet there. Lines written to the command file (`--cmd-file` or `HV_INPUT_FILE`) control it:
`oauthstatus` prints the pending URL and the done flag to stderr, and `oauthmode 0/1` switches
between the two modes.

## Building WinIOSBrowser.exe by hand

The program uses no C runtime. It imports only kernel32 and ws2_32, and its entry point is
`WinMainCRTStartup`. `make guest-tools` runs these commands:

```sh
LLVM=/opt/homebrew/opt/llvm/bin LLD=/opt/homebrew/opt/lld/bin
$LLVM/clang --target=aarch64-pc-windows-msvc -std=c11 -Wall -Wextra -Werror -Os \
    -ffreestanding -nostdlib -fno-builtin -fno-stack-protector \
    -c tools/winios_browser_arm64.c -o build/guest/winios_browser_arm64.obj
$LLVM/llvm-dlltool -m arm64 -d build/guest/kernel32.def -l build/guest/kernel32.lib   # .def files written by make
$LLVM/llvm-dlltool -m arm64 -d build/guest/ws2_32.def   -l build/guest/ws2_32.lib
$LLD/lld-link /machine:arm64 /subsystem:windows,6.02 /entry:WinMainCRTStartup /nodefaultlib \
    /dynamicbase /nxcompat /Brepro /opt:ref /opt:icf /out:build/guest/WinIOSBrowser.exe \
    build/guest/winios_browser_arm64.obj build/guest/kernel32.lib build/guest/ws2_32.lib
```

Check the result with
`/opt/homebrew/opt/llvm/bin/llvm-readobj --file-headers --coff-imports build/guest/WinIOSBrowser.exe`.
It should be `IMAGE_FILE_MACHINE_ARM64` with subsystem `WINDOWS_GUI` and import only from
`kernel32.dll` and `ws2_32.dll`. If you add a Win32 call to the source, add its name to
`GUEST_KERNEL32` or `GUEST_WS2_32` in the Makefile.

## Troubleshooting

- **Links still open in Edge**: WinIOS Browser is not the default. Run `SAFARI-SIGNIN.bat` and pick
  it in Settings. Also check that the toggle in the app is on.
- **The sheet opens but the app never notices the sign-in**: look in `%TEMP%\winios_browser.log`.
  Look for `relay_listening_10.0.2.15:<port>`. `relay_upstream_connect_failed` means nothing was
  listening on `localhost:<port>` in Windows any more; restart the sign-in from the app.
- **A firewall prompt for WinIOS Browser**: the rule is missing. Run `SAFARI-SIGNIN.bat` again, or
  allow it in the prompt for private and public networks.
- **The sheet stays open after the sign-in**: close it by hand. The app may have answered the
  callback with something other than 200, 301 or 302, or the request line did not contain one of
  the callback markers. The sign-in itself has still finished.
