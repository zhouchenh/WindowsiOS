#!/bin/bash
# Development helper for Arch on WindowsiOS: a root service that runs jobs the host puts in the app's
# shared folder (http://10.0.2.4/linux_job.txt: an id line, then shell commands) and uploads the
# output (linux_out.txt). The Linux counterpart of the Windows helper. Remove: systemctl disable --now winios-agent
cat > /usr/local/bin/winios-agent <<'A'
#!/bin/bash
u=http://10.0.2.4
last=$(curl -s --max-time 5 $u/linux_job.txt | head -1)
while true; do
    sleep 1.5
    t=$(curl -s --max-time 5 $u/linux_job.txt) || continue
    id=$(head -1 <<<"$t"); cmd=$(tail -n +2 <<<"$t")
    if [ -n "$id" ] && [ "$id" != "$last" ] && [ -n "$cmd" ]; then
        last=$id
        out=$(timeout 1800 bash -c "$cmd" 2>&1)
        printf '%s\n%s\n' "$id" "$out" | curl -s --max-time 30 -T - $u/linux_out.txt
    fi
done
A
chmod 755 /usr/local/bin/winios-agent
cat > /etc/systemd/system/winios-agent.service <<'S'
[Unit]
Description=WindowsiOS host job runner
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/winios-agent
Restart=always
[Install]
WantedBy=multi-user.target
S
systemctl daemon-reload
systemctl enable --now winios-agent
echo agent-ok
