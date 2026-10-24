"""Shared helpers for verify/*.py. Stdlib only; run as root on the machine with the cards.

Nothing here writes PCI config space or sysfs. Run directly, this file prints the per-device header
as JSON:
    python3 benchlib.py meta [BDF ...]
"""
import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------- shell

def sh(cmd, stdin=None, timeout=300):
    """Run a bash command; return CompletedProcess (text)."""
    return subprocess.run(["bash", "-c", cmd], input=stdin, capture_output=True, text=True, timeout=timeout)


def sh_json(cmd, stdin=None, timeout=300):
    p = sh(cmd, stdin, timeout)
    if p.returncode != 0:
        raise RuntimeError(f"command failed ({p.returncode}): {p.stderr.strip()[-400:]}")
    return json.loads(p.stdout)


# ---------------------------------------------------------------- decoding

def parse_mib(text):
    """'32G' / '256M' / '32768' (MiB) -> MiB int."""
    m = re.fullmatch(r"\s*(\d+)\s*([GgMm]?)i?[Bb]?\s*", text)
    if not m:
        raise argparse.ArgumentTypeError(f"bad size {text!r}; use 32G, 256M or MiB")
    n, unit = int(m.group(1)), m.group(2).upper()
    return n * 1024 if unit == "G" else n


def rebar_cap_sizes_mib(cap):
    """PCIe ReBAR capability register: bit n (4..31) => 2^(n-4) MiB supported."""
    return [1 << (n - 4) for n in range(4, 32) if cap >> n & 1]


def rebar_ctrl(ctrl):
    """PCIe ReBAR control register: bits 2:0 BAR index, 13:8 size (2^n MiB)."""
    return {"bar_index": ctrl & 7, "nbars": ctrl >> 5 & 7, "size_mib": 1 << (ctrl >> 8 & 0x3F)}


def fb_override(v610):
    """MAN-GA102 FB_SIZE_OVERRIDE: EN bit 11, VAL bits 10:7."""
    return {"en": v610 >> 11 & 1, "val": v610 >> 7 & 0xF}


# ---------------------------------------------------------------- per-card state

def _cfg_dword(bdf, off):
    with open(f"/sys/bus/pci/devices/{bdf}/config", "rb") as f:
        data = os.pread(f.fileno(), 4, off)
    return int.from_bytes(data, "little") if len(data) == 4 else None


def _nvsmi_bar1():
    """{bdf: {total,used,free}} in MiB from `nvidia-smi -q -d MEMORY`."""
    try:
        out = subprocess.run(["nvidia-smi", "-q", "-d", "MEMORY"], capture_output=True,
                             text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    res, cur, inbar = {}, None, False
    for line in out.splitlines():
        m = re.match(r"GPU ([0-9A-Fa-f]+):([0-9a-f]{2}:[0-9a-f]{2}\.\d)", line)
        if m:
            cur = f"{int(m.group(1), 16):04x}:{m.group(2).lower()}"
            res[cur], inbar = {}, False
            continue
        s = line.strip()
        if s.startswith("BAR1 Memory Usage"):
            inbar = True
        elif inbar and cur and (m := re.match(r"(Total|Used|Free)\s*:\s*(\d+) MiB", s)):
            res[cur][m.group(1).lower()] = int(m.group(2))
        elif s.endswith("Usage") or s.startswith("Conf Compute"):
            inbar = False
    return res


def host_meta(bdfs=None):
    """Kernel, driver, and per-card BAR1 / expected-size fields."""
    devs = []
    for path in sorted(glob.glob("/sys/bus/pci/devices/*")):
        bdf = os.path.basename(path)
        rd = lambda n: open(f"{path}/{n}").read().strip()
        if rd("vendor") != "0x10de" or not rd("class").startswith("0x0300"):
            continue
        if bdfs and bdf not in bdfs:
            continue
        start, end, _ = (int(x, 16) for x in open(f"{path}/resource").read().split("\n")[1].split())
        drv = os.path.realpath(f"{path}/driver") if os.path.exists(f"{path}/driver") else None
        try:
            resize = rd("resource1_resize")
        except OSError:
            resize = None
        v610, vbbc, vbc0 = (_cfg_dword(bdf, o) for o in (0x610, 0xBBC, 0xBC0))
        caps = rebar_cap_sizes_mib(vbbc) if vbbc is not None else []
        devs.append({
            "bdf": bdf,
            "id": f"{rd('vendor')[2:]}:{rd('device')[2:]}",
            "subsys": f"{rd('subsystem_vendor')[2:]}:{rd('subsystem_device')[2:]}",
            "driver": os.path.basename(drv) if drv else None,
            "region1_mib": (end - start + 1) >> 20 if end else 0,
            "resource1_resize": resize,
            "cfg_610": f"{v610:08x}", "fb_override": fb_override(v610),
            "cfg_bbc": f"{vbbc:08x}", "bbc_max_mib": max(caps) if caps else None,
            "cfg_bc0": f"{vbc0:08x}", "bc0_cur_mib": rebar_ctrl(vbc0)["size_mib"],
        })
    bar1 = _nvsmi_bar1()
    for d in devs:
        b = bar1.get(d["bdf"], {})
        d["bar1_total_mib"], d["bar1_used_mib"] = b.get("total"), b.get("used")
    try:
        drv_ver = open("/sys/module/nvidia/version").read().strip()
    except OSError:
        drv_ver = None
    return {"kernel": os.uname().release, "driver": drv_ver, "devices": devs}


# ---------------------------------------------------------------- drained-card guards

# Per card: processes holding /dev/nvidiaN (scan of /proc/*/fd, so container processes count too),
# three 1 s utilisation samples, free VRAM and pstate. Run as `python3 - BDF` with this on stdin.
PREFLIGHT = r'''
import glob, json, os, re, subprocess, sys
bdf = sys.argv[1]
info = open(f"/proc/driver/nvidia/gpus/{bdf}/information").read()
minor = int(re.search(r"Device Minor:\s*(\d+)", info).group(1))
node = f"/dev/nvidia{minor}"
holders = []
for fd in glob.glob("/proc/[0-9]*/fd/*"):
    try:
        if os.readlink(fd) == node:
            pid = fd.split("/")[2]
            holders.append({"pid": int(pid), "comm": open(f"/proc/{pid}/comm").read().strip()})
    except OSError:
        pass
holders = sorted({h["pid"]: h for h in holders}.values(), key=lambda h: h["pid"])
util = []
for i in range(3):
    q = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu,memory.free,pstate",
                        "--format=csv,noheader,nounits", "-i", bdf], capture_output=True, text=True).stdout
    u, free, ps = (x.strip() for x in q.split(","))
    util.append(int(u))
    if i < 2:
        __import__("time").sleep(1)
print(json.dumps({"minor": minor, "holders": holders, "util_samples": util, "vram_free_mib": int(free),
                  "pstate": ps}))
'''


def kernel_events(bdf, since=None):
    """Xid lines (this card / any card) and AER lines naming the card or its parent port, this boot
    or since an epoch."""
    short = bdf[:-2]  # 0000:01:00
    parent = sh(f"basename $(dirname $(readlink -f /sys/bus/pci/devices/{bdf}))").stdout.strip()
    rng = f"--since @{int(since)}" if since else "-b"
    out = sh(f"journalctl -k {rng} -g 'NVRM: Xid|AER' -o cat --no-pager").stdout
    lines = [l for l in out.splitlines() if l.strip() and not l.startswith("-- ")]
    xid_any = [l for l in lines if "NVRM: Xid" in l]
    xid = [l for l in xid_any if f"Xid (PCI:{short})" in l]
    aer = [l for l in lines if "AER" in l and (bdf in l or (parent and parent in l))]
    return {"xid": len(xid), "xid_any": len(xid_any), "aer": len(aer), "last_xid": xid_any[-1] if xid_any else None}


def preflight_refusals(pf):
    """Reasons to refuse a card: something holds it, or it was not idle."""
    refuse = []
    if pf["holders"]:
        refuse.append("holders: " + ", ".join(f"{h['comm']}({h['pid']})" for h in pf["holders"]))
    if any(pf["util_samples"]):
        refuse.append(f"utilisation not idle {pf['util_samples']}")
    return refuse


def build(name):
    """Compile HERE/<name>.c into a fresh temp dir; return (CompletedProcess, dir or None)."""
    with open(os.path.join(HERE, f"{name}.c")) as f:
        src = f.read()
    p = sh(f"set -e; d=$(mktemp -d /tmp/{name}.XXXXXX); cat > $d/{name}.c; "
           f"gcc -O2 -Wall -o $d/{name} $d/{name}.c -ldl 1>&2; echo $d", stdin=src)
    return p, (p.stdout.strip().splitlines()[-1] if p.returncode == 0 else None)


def run_binary(cmd, hard):
    """Run a test binary under `timeout -s KILL`; parse its JSON stdout and stage markers."""
    p = sh(f"timeout -s KILL {hard} {cmd}", timeout=hard + 30)
    stages = [l.split()[1:] for l in p.stderr.splitlines() if l.startswith("stage ")]
    row = {"rc": p.returncode, "last_stage": stages[-1] if stages else None}
    if p.returncode in (137, -9):  # -9 when timeout's group kill also hits the bash wrapper
        row["killed"] = f"hard timeout {hard}s"
    try:
        row.update(json.loads(p.stdout))
    except ValueError:
        row["stdout_tail"] = p.stdout.strip()[-300:]
    return row


# ---------------------------------------------------------------- record

def norm_bdf(text):
    text = text.lower()
    return text if text.count(":") == 2 else "0000:" + text


def common_args(desc):
    ap = argparse.ArgumentParser(description=desc)
    ap.add_argument("--expect-bar1", type=parse_mib, metavar="SIZE",
                    help="expected BAR1 size (32G, 256M, or MiB); sample is flagged invalid if any "
                         "selected card differs")
    ap.add_argument("--bdf", action="append", metavar="DDDD:BB:DD.F", type=norm_bdf,
                    help="restrict to this card (repeatable); default all NVIDIA VGA devices")
    return ap


def start(script, args):
    """Read BAR1 + expected-size fields first and judge the sample against --expect-bar1."""
    if os.geteuid() != 0:
        # Without root, config space past 0x40 is unreadable and the /proc/*/fd holder scan sees
        # nothing, so the drained-card guard would pass on a card that is in use.
        sys.exit(f"{script}: run as root")
    meta = host_meta(args.bdf)
    reasons = []
    if not meta["devices"]:
        reasons.append("no matching NVIDIA VGA devices")
    exp = args.expect_bar1
    if exp is not None:
        for d in meta["devices"]:
            if d["bar1_total_mib"] != exp:
                reasons.append(f"{d['bdf']} nvidia-smi BAR1 {d['bar1_total_mib']} MiB != {exp}")
            if d["region1_mib"] != exp:
                reasons.append(f"{d['bdf']} region1 {d['region1_mib']} MiB != {exp}")
    return {
        "script": script,
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        **meta,
        "expect_bar1_mib": exp,
        "valid": None if exp is None and meta["devices"] else not reasons,
        "invalid_reasons": reasons,
    }


def emit(rec):
    print(json.dumps(rec, separators=(",", ":")))
    sys.stdout.flush()


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "meta":
    print(json.dumps(host_meta(sys.argv[2:] or None)))
