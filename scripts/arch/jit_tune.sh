#!/bin/bash
# Arch on WindowsiOS: settings that suit the emulator's translator. Run as root; takes effect after a reboot.
#   jit_tune.sh          apply        jit_tune.sh --remove   undo
# 1. No address space randomization. The emulator keeps translated code per (virtual, physical) address;
#    with randomization every new process gets its libraries at new addresses and all of their code is
#    translated again (process start-up about 3x slower).
# 2. Default stack limit 160 MB instead of 8 MB. Without randomization Linux puts the stack top exactly
#    128 MB above the libraries, a multiple of the emulator's 64 MB software TLB, so stack and library pages
#    keep evicting each other; 160 MB moves them apart.
# Trade-off: programs inside the VM lose ASLR, a defence against memory-corruption exploits.
F1=/etc/sysctl.d/90-winios-jit.conf
F2=/etc/systemd/system.conf.d/90-winios-stack.conf
F3=/etc/systemd/user.conf.d/90-winios-stack.conf
F4=/etc/security/limits.d/90-winios-stack.conf
if [ "$1" = --remove ]; then rm -f $F1 $F2 $F3 $F4; echo "removed; reboot to apply"; exit 0; fi
mkdir -p /etc/sysctl.d /etc/systemd/system.conf.d /etc/systemd/user.conf.d /etc/security/limits.d
echo 'kernel.randomize_va_space = 0' > $F1
printf '[Manager]\nDefaultLimitSTACK=160M:infinity\n' > $F2
cp $F2 $F3
printf '*    soft stack 163840\nroot soft stack 163840\n' > $F4
echo "applied; reboot to apply"
