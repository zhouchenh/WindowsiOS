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

DEV = $(B)/acpi.o $(B)/fb_display.o $(B)/fb_metal.o $(B)/fdt.o $(B)/fw_cfg.o $(B)/gicv3.o $(B)/hda.o \
      $(B)/nvme.o $(B)/pcie.o $(B)/pflash.o $(B)/pl011.o $(B)/pl031.o $(B)/pl061.o $(B)/timer.o \
      $(B)/virtio.o $(B)/virtio_blk.o $(B)/virtio_input.o $(B)/virtio_net.o $(B)/virtio_snd.o $(B)/virtio_gpu.o $(B)/virtio_gpu3d.o \
      $(B)/winvirt.o $(B)/xhci.o

VM_HOST = $(B)/winvm.o $(B)/net_slirp.o $(B)/dns_proxy.o $(B)/share.o $(B)/audio_mac.o $(B)/hvsparse.o

MAC_FRAMEWORKS = -framework Cocoa -framework Foundation -framework QuartzCore -framework Metal \
                 -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers \
                 -framework AudioToolbox

CORE_TESTS = $(B)/test_classify $(B)/test_jit_region $(B)/test_operands $(B)/test_jit $(B)/test_mem \
             $(B)/test_mmu $(B)/test_exc

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
$(B)/test_net_ipv6: tests/test_net_ipv6.c host/net_slirp.c host/dns_proxy.c host/*.h $(B)/libresolv_no_ipv6.dylib | $(B)
	$(CC) $(CFLAGS) $(SLIRP_CFLAGS) tests/test_net_ipv6.c host/net_slirp.c host/dns_proxy.c \
	      $(B)/libresolv_no_ipv6.dylib -Wl,-rpath,@executable_path $(SLIRP_LIBS) -lresolv -o $@
# Port forwards (TCP and UDP, IPv4 and IPv6, loopback / local network / VPN, add, edit, remove, port in use, the saved
# list) through libslirp to a stand-in guest that echoes: no network needed.
$(B)/test_net_fwd: tests/test_net_fwd.c host/net_slirp.c host/dns_proxy.c host/*.h | $(B)
	$(CC) $(CFLAGS) $(SLIRP_CFLAGS) tests/test_net_fwd.c host/net_slirp.c host/dns_proxy.c $(SLIRP_LIBS) -lresolv -o $@
test-net: $(B)/test_net_ipv6 $(B)/test_net_fwd
	$(B)/test_net_ipv6
	$(B)/test_net_fwd

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

.PHONY: all test-core test-dns test-net ios-lib clean

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
