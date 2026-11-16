#!/bin/bash
# CPU micro benchmarks for the emulator (also runs on macOS for a native reference).
# Each line: name seconds. Output also to /root/cpubench.txt when run as root in the guest.
t() { local s=$(date +%s.%N 2>/dev/null || python3 -c 'import time;print(time.time())'); "$@" >/dev/null 2>&1; local e=$(date +%s.%N 2>/dev/null); awk "BEGIN{printf \"%.3f\", $e - $s}"; }
T=${TMPDIR:-/tmp}
head -c 33554432 /dev/urandom > $T/cb.rand 2>/dev/null
seq 1 400000 > $T/cb.seq
{
echo "sha256_64MB $(t sh -c "cat $T/cb.rand $T/cb.rand | openssl dgst -sha256")"
echo "gzip_32MB $(t sh -c "gzip -1 -c $T/cb.seq $T/cb.rand > /dev/null")"
echo "sort_400k $(t sh -c "sort -R $T/cb.seq | sort -n > /dev/null")"
echo "awk_loop $(t awk 'BEGIN{s=0;for(i=0;i<3000000;i++)s+=i%7;print s}')"
echo "fork_exec_300 $(t sh -c 'for i in $(seq 300); do /bin/sh -c true; done')"
echo "syscalls_dd $(t dd if=/dev/zero of=/dev/null bs=64 count=300000)"
echo "pipe_256MB $(t sh -c 'head -c 268435456 /dev/zero | cat > /dev/null')"
echo "mmap_touch $(t sh -c 'head -c 400000000 /dev/zero | tail -c 1')"
} | tee $T/cpubench.out
rm -f $T/cb.rand $T/cb.seq
