#!/usr/bin/env python3
"""Automatic smoothness test on a connected iPad/iPhone (direct install, not LiveContainer).

For every configuration: restart the app with that setting, enable JIT through LLDB, let Windows
start by itself, run the in-guest benchmark (bench.ps1 moves a window for N seconds), and collect
  - guest side: frames Windows composed per second, worst frame gap, per-CPU load, per-process load
  - host side:  frames the app put on screen per second, engine statistics, where host CPU time went
Nothing is changed for good: settings are passed as launch arguments and environment variables.

  python3 scripts/bench/bench_device.py                 # the default matrix
  python3 scripts/bench/bench_device.py --only baseline # one configuration
The device must be unlocked; Windows must already be set up with the 3D driver and network.
"""
import argparse, collections, json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HERE = os.path.dirname(os.path.abspath(__file__))

CONFIGS = [
    # tag, what it is, environment, launch arguments (NSUserDefaults overrides)
    ("baseline", "默认：3D 开，HiDPI 关，JIT 缓存 768 MB，内存 8 GB", {}, []),
    ("hidpi", "HiDPI 开", {}, ["-winios.hiDPIDisplay", "YES"]),
    ("jit256", "JIT 缓存 256 MB", {}, ["-winios.jitMB", "256"]),
    ("ram4g", "内存 4 GB", {}, ["-winios.ramMB", "4096"]),
    ("nospin", "等中断时不空转 (HV_WFI_SPIN=0)", {"HV_WFI_SPIN": "0"}, []),
]


def run(cmd, timeout=None, check=False):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=check)


class Device:
    def __init__(self, a):
        self.udid, self.core, self.bundle, self.out = a.udid, a.coredevice, a.bundle, a.out

    def dc(self, *args, timeout=120):
        return run(["xcrun", "devicectl", "device", *args, "--device", self.udid], timeout=timeout)

    def push(self, src, dst):
        r = self.dc("copy", "to", "--domain-type", "appDataContainer", "--domain-identifier", self.bundle,
                    "--source", src, "--destination", dst)
        return "File Size" in r.stdout

    def pull(self, src, dst):
        if os.path.exists(dst): os.unlink(dst)
        self.dc("copy", "from", "--domain-type", "appDataContainer", "--domain-identifier", self.bundle,
                "--source", src, "--destination", dst)
        return open(dst, errors="replace").read() if os.path.exists(dst) else ""

    def push_text(self, text, dst):
        p = os.path.join(self.out, "_tmp_push")
        open(p, "w").write(text)
        return self.push(p, dst)

    def pid(self):
        r = self.dc("info", "processes")
        for line in r.stdout.splitlines():
            if "WindowsiOS.app/WindowsiOS" in line: return int(line.split()[0])
        return None

    def status(self):
        t = self.pull("Documents/boot_status.txt", os.path.join(self.out, "_status.txt"))
        g = lambda k, d=None: (re.search(k + r"[:=] ?([\w.]+)", t) or [None, d])[1]
        return {"raw": t, "uptime": float(g("uptime_sec", 0) or 0), "frames": int(g("frames_presented", 0) or 0),
                "running": g("vm_running") == "true", "stage": g("stage"), "kbd": g("usb_kbd_ready") == "1",
                "idle": float(g("wfi_idle_pct", 0) or 0), "jit_used": float(g("jit_used_mb", 0) or 0),
                "flushes": int(g("jit_full_flushes", 0) or 0), "ram": g("ram_mb"), "three_d": g("3d"),
                "scanout": (re.search(r"scanout=\d+ (\S+)", t) or [None, None])[1]}


def start_app(dev, tag, env, args, log):
    env = dict({"HV_STATS": "10", "HV_PROF_IOS": "1", "HV_PROF_IOS_SECS": "10", "WINIOS_CONSOLE": "1"}, **env)
    console = open(os.path.join(dev.out, f"{tag}.console.log"), "w")
    cmd = ["xcrun", "devicectl", "device", "process", "launch", "--device", dev.udid, "--console", "--start-stopped",
           "--terminate-existing", "--environment-variables", json.dumps(env), "--", dev.bundle,
           "-winios.autoStart", "YES", *args]
    proc = subprocess.Popen(cmd, stdout=console, stderr=subprocess.STDOUT)
    pid = None
    for _ in range(15):
        time.sleep(2)
        pid = dev.pid()
        if pid or proc.poll() is not None: break
    if not pid:
        raise RuntimeError("the app did not start (is the device unlocked?): see " + console.name)
    log(f"  app started (pid {pid}); enabling JIT, about 2 minutes")
    r = run(["lldb", "-b", "-o", "script lldb.debugger.SetAsync(False)", "-o", f"device select {dev.core}",
             "-o", f"device process attach -p {pid}",
             "-o", f"command script import {ROOT}/scripts/_lldb_txm_jit.py", "-o", "txm_jit_run"], timeout=420)
    open(os.path.join(dev.out, f"{tag}.lldb.log"), "w").write(r.stdout + r.stderr)
    if "SUCCESS" not in r.stdout: raise RuntimeError("JIT was not enabled: see " + tag + ".lldb.log")
    return proc, console.name


def wait_desktop(dev, log, timeout=300):
    t0 = time.time(); seen = None
    while time.time() - t0 < timeout:
        s = dev.status()
        if s["running"] and s["stage"] == "os" and s["kbd"] and s["uptime"] >= 70:
            return s
        if (s["stage"], int(s["uptime"] // 30)) != seen:
            seen = (s["stage"], int(s["uptime"] // 30)); log(f"  waiting for the desktop: stage={s['stage']} uptime={s['uptime']:.0f}s")
        time.sleep(5)
    raise RuntimeError("Windows did not reach the desktop")


def bench(dev, tag, seconds, log):
    dev.push(os.path.join(HERE, "bench.ps1"), "Documents/Shared/bench.ps1")
    dev.push_text(f"{tag} {seconds}\n", "Documents/Shared/bench_cfg.txt")
    dev.push_text("pending\n", "Documents/Shared/bench_result.txt")
    samples = []
    for attempt in (1, 2):
        dev.push_text('!powershell -ExecutionPolicy Bypass -c "irm http://10.0.2.4/bench.ps1 | iex"', "Documents/type.request")
        t_typed = time.time()
        while time.time() - t_typed < seconds + 110:
            s = dev.status(); samples.append((time.time(), s))
            res = dev.pull("Documents/Shared/bench_result.txt", os.path.join(dev.out, "_result.txt"))
            if f"tag={tag}" in res and "finished=" in res:
                return dict(l.strip().split("=", 1) for l in res.splitlines() if "=" in l), samples, time.time()
            time.sleep(3)
        log("  no result from the guest; typing the command once more")
    raise RuntimeError("the guest benchmark never reported")


def host_fps(samples, t_end, seconds):
    """Frames the app presented per second of guest uptime, inside the benchmark window."""
    win = [s for t, s in samples if t_end - seconds - 4 <= t <= t_end - 2]
    pts = sorted({(s["uptime"], s["frames"]) for s in win})
    if len(pts) < 2 or pts[-1][0] <= pts[0][0]: return None, None
    idle = [s["idle"] for s in win]
    return (pts[-1][1] - pts[0][1]) / (pts[-1][0] - pts[0][0]), sum(idle) / len(idle)


def parse_console(path, start_off, end_off, dsym):
    text = open(path, errors="replace").read()[start_off:end_off]
    dumps, cur = [], None
    for l in text.splitlines():
        m = re.match(r"hvprof: (\d+) samples, idle ([\d.]+)%, of busy: jit ([\d.]+)%, other images ([\d.]+)%", l)
        if m:
            cur = {"busy": float(m[1]) * (1 - float(m[2]) / 100), "idle": float(m[2]), "jit": float(m[3]), "oth": float(m[4]),
                   "host": [], "other": [], "threads": []}
            dumps.append(cur); continue
        if not cur: continue
        m = re.match(r"hvprof:\s+([\d.]+)% \+(0x[0-9a-f]+)", l)
        if m: cur["host"].append((float(m[1]), int(m[2], 16))); continue
        m = re.match(r"hvprof: other\s+([\d.]+)% (\S+)", l)
        if m: cur["other"].append((float(m[1]), m[2])); continue
        if l.startswith("hvprof: threads"): cur["threads"] = [float(x) for x in re.findall(r"\] ([\d.]+)%", l)]
    out = {"dumps": len(dumps)}
    stats = re.findall(r"^stats.*$", text, re.M)
    def avg(pat):
        v = [float(m[1]) for s in stats for m in [re.search(pat, s)] if m]
        return sum(v) / len(v) if v else None
    out.update(exc_per_s=avg(r"exc (\d+)/s"), irq_per_s=avg(r"irq (\d+)/s"), translated_per_s=avg(r"translated (\d+)/s"),
               translate_pct=avg(r"; (\d+)% of time"))
    if not dumps: return out
    tot = sum(d["busy"] for d in dumps) or 1
    out["jit_pct"] = sum(d["jit"] * d["busy"] for d in dumps) / tot
    out["other_pct"] = sum(d["oth"] * d["busy"] for d in dumps) / tot
    nt = max(len(d["threads"]) for d in dumps)
    out["cpu_busy"] = [sum(d["threads"][i] for d in dumps if len(d["threads"]) > i) / len(dumps) for i in range(nt)]
    agg, oth = collections.Counter(), collections.Counter()
    for d in dumps:
        for pct, off in d["host"]: agg[off] += pct / 100 * d["busy"]
        for pct, name in d["other"]: oth[name] += pct / 100 * d["busy"]
    fn = collections.Counter()
    offs = sorted(agg, key=lambda o: -agg[o])
    if offs and os.path.exists(dsym):
        names = run(["atos", "-o", dsym, "-arch", "arm64", "-l", "0x100000000"] + [hex(0x100000000 + o) for o in offs]).stdout.strip().split("\n")
        for o, s in zip(offs, names): fn[re.sub(r" \(in .*", "", s)] += agg[o]
    out["host_top"] = [(f, round(100 * n / tot, 1)) for f, n in fn.most_common(8)]
    out["other_top"] = [(f, round(100 * n / tot, 1)) for f, n in oth.most_common(6)]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--udid", default="YOUR_IPAD_UDID")
    ap.add_argument("--coredevice", default="YOUR_COREDEVICE_ID")
    ap.add_argument("--bundle", default="your.bundle.id")
    ap.add_argument("--seconds", type=int, default=40)
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--out", default=os.path.join(HERE, "results", time.strftime("%Y%m%d-%H%M%S")))
    ap.add_argument("--dsym", default=os.path.join(ROOT, "build/DerivedData-iPad/Build/Products/Release-iphoneos/WindowsiOS.app.dSYM/Contents/Resources/DWARF/WindowsiOS"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    dev = Device(a)
    logf = open(os.path.join(a.out, "run.log"), "a")
    def log(msg):
        line = time.strftime("%H:%M:%S ") + msg
        print(line, flush=True); logf.write(line + "\n"); logf.flush()
    results = []
    for tag, desc, env, args in CONFIGS:
        if a.only and tag not in a.only: continue
        log(f"[{tag}] {desc}")
        rec = {"tag": tag, "desc": desc}
        proc = None
        try:
            proc, console = start_app(dev, tag, env, args, log)
            s = wait_desktop(dev, log)
            log(f"  desktop up (uptime {s['uptime']:.0f}s, 3d={s['three_d']}, scanout {s['scanout']}); settling 40 s")
            time.sleep(40)
            off0 = os.path.getsize(console)
            guest, samples, t_end = bench(dev, tag, a.seconds, log)
            off1 = os.path.getsize(console)
            fps, idle = host_fps(samples, t_end, a.seconds)
            last = samples[-1][1]
            rec.update(guest=guest, host_fps=fps, host_idle_pct=idle, ram_mb=last["ram"], three_d=last["three_d"],
                       scanout=last["scanout"], jit_used_mb=last["jit_used"], jit_full_flushes=last["flushes"],
                       prof=parse_console(console, off0, off1, a.dsym))
            log(f"  guest {guest.get('steps_per_s')} steps/s, worst gap {guest.get('worst_step_ms')} ms; host {fps and round(fps, 1)} fps")
        except Exception as e:
            rec["error"] = str(e); log("  FAILED: " + str(e))
        results.append(rec)
        json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=1, ensure_ascii=False)
    log("done: " + os.path.join(a.out, "results.json"))


if __name__ == "__main__":
    main()
