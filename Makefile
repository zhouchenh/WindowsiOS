CC = clang
CFLAGS = -std=c11 -Wall -Wextra -O2 -g -Icore -Ihost -Idevices
OBJCFLAGS = -fobjc-arc -Wall -Wextra -O2 -g -Icore -Ihost -Idevices
B = build

SLIRP_CFLAGS = $(shell PATH=/opt/homebrew/bin:$$PATH pkg-config --cflags slirp)
SLIRP_LIBS = $(shell PATH=/opt/homebrew/bin:$$PATH pkg-config --libs slirp)

CORE = $(B)/classify.o $(B)/operands.o $(B)/translate.o $(B)/dispatch.o $(B)/mmu.o $(B)/memop.o \
       $(B)/exception.o $(B)/sysreg.o $(B)/machine.o
HOST = $(B)/jit_region.o $(B)/enter.o $(B)/disk.o
ENGINE = $(CORE) $(HOST)

DEV = $(B)/acpi.o $(B)/acpi_battery.o $(B)/fb_display.o $(B)/fb_metal.o $(B)/fdt.o $(B)/fw_cfg.o $(B)/gicv3.o $(B)/hda.o \
      $(B)/nvme.o $(B)/pcie.o $(B)/pflash.o $(B)/pl011.o $(B)/pl031.o $(B)/pl061.o $(B)/timer.o \
      $(B)/virtio.o $(B)/virtio_blk.o $(B)/virtio_input.o $(B)/virtio_net.o $(B)/virtio_snd.o $(B)/virtio_gpu.o $(B)/virtio_gpu3d.o \
      $(B)/usb_touch.o $(B)/winvirt.o $(B)/xhci.o $(B)/neptune_hook.o $(B)/neptune_cleanup.o $(B)/neptune_device.o $(B)/dxmt_shared_init.o $(B)/dxmt_data_lock.o

VM_HOST = $(B)/winvm.o $(B)/net_slirp.o $(B)/dns_proxy.o $(B)/share.o $(B)/audio_mac.o $(B)/hvsparse.o

MAC_FRAMEWORKS = -framework Cocoa -framework Foundation -framework QuartzCore -framework Metal \
                 -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
                 -framework AudioToolbox

CORE_TESTS = $(B)/test_classify $(B)/test_jit_region $(B)/test_operands $(B)/test_jit $(B)/test_mem \
             $(B)/test_mmu $(B)/test_exc $(B)/test_share_clip $(B)/test_share_focus $(B)/test_pl031 \
             $(B)/test_acpi $(B)/test_usb_touch $(B)/test_gpu_mode $(B)/test_audio_keepalive

all: $(CORE_TESTS) $(B)/hvsparse $(B)/winvm

# mmu.c: no SIMD (hv_tlb_refill runs with the guest's SIMD registers live).
$(B)/mmu.o: core/mmu.c core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -mgeneral-regs-only -c $< -o $@
$(B)/net_slirp.o: host/net_slirp.c host/*.h core/*.h devices/*.h | $(B)
	$(CC) $(CFLAGS) $(SLIRP_CFLAGS) -c $< -o $@
$(B)/fb_metal.o: devices/fb_metal.m devices/*.h core/*.h host/*.h | $(B)
	$(CC) $(OBJCFLAGS) -c $< -o $@
$(B)/main_mac.o: host/main_mac.m host/*.h core/*.h devices/*.h | $(B)
	$(CC) $(OBJCFLAGS) -c $< -o $@
$(B)/%.o: core/%.c core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: host/%.c host/*.h core/*.h devices/*.h | $(B)
	$(CC) $(CFLAGS) -c $< -o $@
$(B)/%.o: host/%.S | $(B)
	$(CC) -c $< -o $@
$(B)/%.o: devices/%.c devices/*.h core/*.h host/*.h | $(B)
	$(CC) $(CFLAGS) -c $< -o $@

$(B)/winvm: $(B)/main_mac.o $(ENGINE) $(DEV) $(VM_HOST)
	$(CC) $(B)/main_mac.o $(ENGINE) $(DEV) $(VM_HOST) $(SLIRP_LIBS) $(MAC_FRAMEWORKS) -o $@

$(B)/test_classify: tests/test_classify.c tests/classify_cases.s $(B)/classify.o
	$(CC) $(CFLAGS) $^ -o $@
$(B)/test_jit_region: tests/test_jit_region.c $(B)/jit_region.o
	$(CC) $(CFLAGS) $^ -o $@
$(B)/test_operands: tests/test_operands.c tests/operand_cases.s $(B)/operands.o
	$(CC) $(CFLAGS) $^ -o $@
$(B)/test_mmu: tests/test_mmu.c $(ENGINE)
	$(CC) $(CFLAGS) tests/test_mmu.c $(ENGINE) -o $@
# The shared clipboard (host/share.c) over its socket, under the address and UB sanitizers.
# share.c's /.henge/forwards calls the port-forward engine: stubbed (tests/share_net_fwd_stub.c).
$(B)/test_share_clip: tests/test_share_clip.c host/share.c host/share.h tests/share_net_fwd_stub.c | $(B)
	$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-sanitize-recover=all tests/test_share_clip.c host/share.c \
		tests/share_net_fwd_stub.c -o $@
# /.henge/focus (the WinKit focus agent's endpoint) over the same socket.
$(B)/test_share_focus: tests/test_share_focus.c host/share.c host/share.h tests/share_net_fwd_stub.c | $(B)
	$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-sanitize-recover=all tests/test_share_focus.c host/share.c \
		tests/share_net_fwd_stub.c -o $@
# The PL031 RTC alone (UTC, HV_RTC=localtime, guest writes, the alarm), with a stand-in machine and GIC.
$(B)/test_pl031: tests/test_pl031.c devices/pl031.c devices/pl031.h | $(B)
	$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-sanitize-recover=all tests/test_pl031.c devices/pl031.c -o $@
# The DSDT with and without the battery (structure, AML bytes, the GED's _EVT) and the battery registers;
# fw_cfg is a stand-in that keeps the files. Under the address and UB sanitizers.
$(B)/test_acpi: tests/test_acpi.c tests/fw_cfg_capture_stub.c tests/fw_cfg_capture_stub.h devices/acpi.c \
                devices/acpi_battery.c devices/*.h | $(B)
	$(CC) $(CFLAGS) -Itests -fsanitize=address,undefined -fno-sanitize-recover=all tests/test_acpi.c \
		tests/fw_cfg_capture_stub.c devices/acpi.c devices/acpi_battery.c -o $@
# The USB touch screen (xHCI port 3): descriptors, report packing, enumeration of all three ports, the touch
# queue and its delivery, driven through the controller's registers over stand-in guest memory.
$(B)/test_usb_touch: tests/test_usb_touch.c devices/xhci.c devices/usb_touch.c devices/*.h core/*.h | $(B)
	$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-sanitize-recover=all tests/test_usb_touch.c devices/xhci.c \
		devices/usb_touch.c -o $@
# The graphics hot switch (virtio_gpu.c: what each driver start is offered, 3D or 2D, the firmware-stage guess after
# a switch) with stand-ins for the transport and the 3D renderer, and fb_display.c's override ownership.
$(B)/test_gpu_mode: tests/test_gpu_mode.c devices/virtio_gpu.c devices/fb_display.c devices/*.h core/*.h | $(B)
	$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-sanitize-recover=all tests/test_gpu_mode.c devices/virtio_gpu.c \
		devices/fb_display.c -framework CoreFoundation -o $@
# The server mode's audio keep-alive (audio_mac.c) over this Mac's own output unit, playing silence, with a stand-in
# HDA. Skipped where there is no output device.
$(B)/test_audio_keepalive: tests/test_audio_keepalive.c host/audio_mac.c host/audio_mac.h | $(B)
	$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-sanitize-recover=all tests/test_audio_keepalive.c host/audio_mac.c \
		-framework AudioToolbox -framework CoreFoundation -o $@

# Guest DNS proxy against a stand-in resolver (no network needed).
$(B)/test_dns_lifecycle: tests/test_dns_lifecycle.c $(B)/dns_proxy.o
	$(CC) $(CFLAGS) $^ -o $@
# Its parser and reply builder against malformed and oversized frames, under the address and UB sanitizers.
$(B)/test_dns_parse: tests/test_dns_parse.c host/dns_proxy.c host/dns_proxy.h | $(B)
	$(CC) $(CFLAGS) -fsanitize=address,undefined -fno-sanitize-recover=all tests/test_dns_parse.c host/dns_proxy.c -o $@
test-dns: $(B)/test_dns_lifecycle $(B)/test_dns_parse
	$(B)/test_dns_lifecycle
	$(B)/test_dns_parse

# The guest's network end to end (IPv6 router and neighbour discovery, DNS over IPv6 and IPv4, fail-fast
# connections, HV_IPV6=0): host/net_slirp.c and dns_proxy.c over Homebrew's libslirp, with stand-ins for the
# virtio-net device and the system resolver. No network needed. libresolv_no_ipv6.dylib hides this Mac's IPv6
# name servers from libslirp, so the DNS proxy's own announcement is what gets tested.
$(B)/libresolv_no_ipv6.dylib: tests/resolv_no_ipv6.c | $(B)
	$(CC) $(CFLAGS) -dynamiclib -install_name @rpath/libresolv_no_ipv6.dylib $< -lresolv -o $@
$(B)/test_net_ipv6: tests/test_net_ipv6.c tests/fake_ifaddrs.h host/net_slirp.c host/dns_proxy.c host/*.h $(B)/libresolv_no_ipv6.dylib | $(B)
	$(CC) $(CFLAGS) $(SLIRP_CFLAGS) tests/test_net_ipv6.c host/net_slirp.c host/dns_proxy.c \
	      $(B)/libresolv_no_ipv6.dylib -Wl,-rpath,@executable_path $(SLIRP_LIBS) -lresolv -o $@
# Port forwards (TCP and UDP, IPv4 and IPv6, loopback / local network / VPN, add, edit, remove, port in use, the saved
# list) through libslirp to a stand-in guest that echoes, and the addresses each scope listens on over made-up
# interfaces (tests/fake_ifaddrs.h): no network needed.
$(B)/test_net_fwd: tests/test_net_fwd.c tests/fake_ifaddrs.h host/net_slirp.c host/dns_proxy.c host/*.h | $(B)
	$(CC) $(CFLAGS) $(SLIRP_CFLAGS) tests/test_net_fwd.c host/net_slirp.c host/dns_proxy.c $(SLIRP_LIBS) -lresolv -o $@
test-net: $(B)/test_net_ipv6 $(B)/test_net_fwd
	$(B)/test_net_ipv6
	$(B)/test_net_fwd

# Pinned Neptune/DXMT ABI guards and native cleanup/lifetime failure cases.
$(B)/test_neptune_cleanup: tests/test_neptune_cleanup.c devices/neptune_cleanup.c devices/neptune_cleanup.h | $(B)
	$(CC) $(CFLAGS) -Werror -pthread -fsanitize=address,undefined -fno-sanitize-recover=all $< -o $@
test-neptune: $(B)/test_neptune_cleanup
	python3 tests/test_neptune_hook.py
	python3 tests/test_neptune_device.py
	ASAN_OPTIONS=detect_leaks=0 $(B)/test_neptune_cleanup
$(B)/test_fb_capture: tests/test_fb_capture.m devices/fb_metal.m devices/fb_display.c devices/*.h core/*.h | $(B)
	$(CC) $(OBJCFLAGS) -Werror -fsanitize=address,undefined -fno-sanitize-recover=all \
		tests/test_fb_capture.m devices/fb_display.c -framework Foundation -framework Metal \
		-framework QuartzCore -framework CoreGraphics -framework ImageIO -o $@
test-fb-capture: $(B)/test_fb_capture
	ASAN_OPTIONS=detect_leaks=0 $(B)/test_fb_capture
test-dxmt-shared-init:
	python3 tests/test_dxmt_shared_init.py

$(B)/hvsparse: tools/hvsparse_main.c host/hvsparse.c host/hvsparse.h | $(B)
	$(CC) $(CFLAGS) tools/hvsparse_main.c host/hvsparse.c -o $@

$(B)/test_%: tests/test_%.c tests/%_programs.S tests/harness.S tests/harness.h $(ENGINE)
	$(CC) $(CFLAGS) -Itests tests/test_$*.c tests/$*_programs.S tests/harness.S $(ENGINE) -o $@

test-core: $(CORE_TESTS)
	@ulimit -s 65520; for t in $(CORE_TESTS); do echo "== $$t"; $$t || exit 1; done

$(B):
	mkdir -p $(B)

# ---- iOS static library target: build/ios/libwinvm.a ----
IOS_SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)
IOS_CC = xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -isysroot $(IOS_SDK)
IOS_SLIRP_INC ?= ios/deps/include/slirp
IOS_CFLAGS = -std=c11 -Wall -Wextra -O2 -g -Icore -Ihost -Idevices -I$(IOS_SLIRP_INC)
IOS_OBJCFLAGS = -fobjc-arc -Wall -Wextra -O2 -g -Icore -Ihost -Idevices
IB = build/ios

IOS_C_SRC = $(wildcard core/*.c) \
            host/jit_region.c host/disk.c host/winvm.c host/net_slirp.c host/dns_proxy.c host/share.c \
            host/audio_mac.c host/hvsparse.c host/prof_ios.c \
            $(wildcard devices/*.c)
IOS_OBJ = $(patsubst %.c,$(IB)/%.o,$(IOS_C_SRC)) $(IB)/host/enter.o $(IB)/devices/fb_metal.o

$(IB)/core/mmu.o: core/mmu.c core/*.h host/*.h devices/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_CFLAGS) -mgeneral-regs-only -c $< -o $@
$(IB)/%.o: %.c core/*.h host/*.h devices/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_CFLAGS) -c $< -o $@
$(IB)/devices/fb_metal.o: devices/fb_metal.m devices/*.h core/*.h host/*.h
	@mkdir -p $(dir $@)
	$(IOS_CC) $(IOS_OBJCFLAGS) -c $< -o $@
$(IB)/host/enter.o: host/enter.S
	@mkdir -p $(dir $@)
	$(IOS_CC) -c $< -o $@
$(IB)/libwinvm.a: $(IOS_OBJ)
	rm -f $@
	xcrun --sdk iphoneos libtool -static -o $@ $(IOS_OBJ)

ios-lib: $(IB)/libwinvm.a

clean:
	rm -rf $(B)

.PHONY: all test-core test-dns test-net test-neptune test-fb-capture test-dxmt-shared-init ios-lib clean

# ---- Windows guest tools: build/guest/WinIOSBrowser.exe (the OAuth bridge, see docs/oauth-bridge.md) ----
# Freestanding AArch64 Win32: no CRT, only kernel32/ws2_32 imports. Needs Homebrew llvm and lld.
# The import libraries come from short export lists via llvm-dlltool (no Windows SDK needed).
GUEST_LLVM ?= /opt/homebrew/opt/llvm/bin
GUEST_LLD ?= /opt/homebrew/opt/lld/bin
GUEST_CC = $(GUEST_LLVM)/clang --target=aarch64-pc-windows-msvc
GUEST_CFLAGS = -std=c11 -Wall -Wextra -Werror -Os -ffreestanding -nostdlib -fno-builtin -fno-stack-protector
GUEST_LDFLAGS = /machine:arm64 /subsystem:windows,6.02 /entry:WinMainCRTStartup /nodefaultlib /dynamicbase /nxcompat \
                /Brepro /opt:ref /opt:icf
GB = $(B)/guest
GUEST_KERNEL32 = GetCommandLineW GetModuleFileNameW GetTempPathW GetFileAttributesW WideCharToMultiByte \
                 MultiByteToWideChar CreateFileW WriteFile CloseHandle CreateProcessW CreateThread \
                 WaitForMultipleObjects Sleep GetTickCount64 GetProcessHeap HeapAlloc HeapFree ExitProcess
GUEST_WS2_32 = WSAStartup socket setsockopt bind listen accept connect send recv shutdown closesocket select

$(GB)/kernel32.lib: Makefile | $(GB)
	{ echo 'LIBRARY kernel32.dll'; echo 'EXPORTS'; for f in $(GUEST_KERNEL32); do echo "$$f"; done; } > $(GB)/kernel32.def
	$(GUEST_LLVM)/llvm-dlltool -m arm64 -d $(GB)/kernel32.def -l $@
$(GB)/ws2_32.lib: Makefile | $(GB)
	{ echo 'LIBRARY ws2_32.dll'; echo 'EXPORTS'; for f in $(GUEST_WS2_32); do echo "$$f"; done; } > $(GB)/ws2_32.def
	$(GUEST_LLVM)/llvm-dlltool -m arm64 -d $(GB)/ws2_32.def -l $@
$(GB)/winios_browser_arm64.obj: tools/winios_browser_arm64.c | $(GB)
	$(GUEST_CC) $(GUEST_CFLAGS) -c $< -o $@
$(GB)/WinIOSBrowser.exe: $(GB)/winios_browser_arm64.obj $(GB)/kernel32.lib $(GB)/ws2_32.lib
	$(GUEST_LLD)/lld-link $(GUEST_LDFLAGS) /out:$@ $^

$(GB):
	mkdir -p $(GB)

guest-tools: $(GB)/WinIOSBrowser.exe

.PHONY: guest-tools

# ---- the WinKit disk: dist/WinKit/drivers.img (64 MB, MBR, one FAT32 partition labelled WINKIT) ----
# winkit/ without its README, plus WinIOSBrowser.exe; scripts/embed_gpu3d.sh puts it into the app.
winkit-img: $(GB)/WinIOSBrowser.exe
	scripts/make_winkit_img.sh dist/WinKit/drivers.img $(GB)/WinIOSBrowser.exe

.PHONY: winkit-img

# Manual shared-initialization diagnostic; deliberately not part of guest-tools,
# winkit-img or START.bat. Manually copy this executable and tools/shared_init_probe.ps1
# to the same guest folder when running the approved diagnostic.
SHARED_PROBE_KERNEL32 = GetStdHandle WriteFile CreateThread CloseHandle GetTickCount64 Sleep ExitProcess
$(GB)/shared_probe_kernel32.lib: Makefile | $(GB)
	{ echo 'LIBRARY kernel32.dll'; echo 'EXPORTS'; for f in $(SHARED_PROBE_KERNEL32); do echo "$$f"; done; } > $(GB)/shared_probe_kernel32.def
	$(GUEST_LLVM)/llvm-dlltool -m arm64 -d $(GB)/shared_probe_kernel32.def -l $@
$(GB)/shared_probe_d3d11.lib: Makefile | $(GB)
	{ echo 'LIBRARY d3d11.dll'; echo 'EXPORTS'; echo 'D3D11CreateDevice'; } > $(GB)/shared_probe_d3d11.def
	$(GUEST_LLVM)/llvm-dlltool -m arm64 -d $(GB)/shared_probe_d3d11.def -l $@
$(GB)/shared_probe_dxgi.lib: Makefile | $(GB)
	{ echo 'LIBRARY dxgi.dll'; echo 'EXPORTS'; echo 'CreateDXGIFactory1'; } > $(GB)/shared_probe_dxgi.def
	$(GUEST_LLVM)/llvm-dlltool -m arm64 -d $(GB)/shared_probe_dxgi.def -l $@
$(GB)/shared_init_probe_arm64.obj: tools/shared_init_probe_arm64.c | $(GB)
	$(GUEST_CC) $(GUEST_CFLAGS) -c $< -o $@
$(GB)/SharedInitProbe.exe: $(GB)/shared_init_probe_arm64.obj $(GB)/shared_probe_kernel32.lib $(GB)/shared_probe_d3d11.lib $(GB)/shared_probe_dxgi.lib
	$(GUEST_LLD)/lld-link $(filter-out /subsystem:%,$(GUEST_LDFLAGS)) /subsystem:console,6.02 /out:$@ $^
shared-init-probe: $(GB)/SharedInitProbe.exe
.PHONY: shared-init-probe

# Host-side simulated COM/GPU ordering only; never launches the Windows binary.
$(B)/test_shared_init_probe: tests/test_shared_init_probe.c tools/shared_init_probe_arm64.c | $(B)
	$(CC) $(CFLAGS) -Werror -fno-builtin $< -o $@
test-shared-init-probe: $(B)/test_shared_init_probe
	@for c in control control-data late-zero late-data fixed baseline event-timeout shared-error unsupported bgra-late bgra-control a8-fixed; do $< $$c || exit; done
.PHONY: test-shared-init-probe
