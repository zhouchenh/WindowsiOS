#!/bin/bash
# vkmark under several host settings, each in a fresh app start (Arch on the iPad):
#   vk_matrix.sh 'name={"ENV":"value",...}' ...     -> one line per run: name score score
# The guest needs /root/gb1.sh (scripts/arch/gb1.sh).
cd "$(dirname "$0")/../.."
export ARCH_DEV_DIR=${ARCH_DEV_DIR:-/tmp/archdev}
for spec in "$@"; do
    name=${spec%%=*}; envj=${spec#*=}
    ARCH_ENV="$envj" scripts/arch_dev.sh boot >/dev/null
    sleep 150
    s=""
    for i in 1 2; do
        out=$(scripts/arch_job.sh "bash /root/gb1.sh vk m$i" 300)
        s="$s $(echo "$out" | grep -o 'Score: [0-9]*' | awk '{print $2}')"
        [ -z "$(echo "$out" | grep -o 'Score')" ] && s="$s fail"
    done
    echo "$name$s"
done
