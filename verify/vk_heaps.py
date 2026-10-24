#!/usr/bin/env python3
"""Vulkan memory heaps per GPU from `vulkaninfo`. Primary signal: the size of the heap that carries a
DEVICE_LOCAL|HOST_VISIBLE memory type. On NVIDIA it is a separate ~256 MiB-class heap with a small BAR1
and becomes the whole VRAM heap when BAR1 covers VRAM. Read-only."""
import re

import benchlib

DL, HV, HC = 1, 2, 4


def parse(text):
    gpus, g, cur = [], None, None
    for line in text.splitlines():
        if m := re.match(r"GPU(\d+):$", line):
            g = {"gpu": int(m.group(1)), "heaps": {}, "types": {}, "pci": {}}
            gpus.append(g)
            cur = None
            continue
        if g is None:
            continue
        s = line.strip()
        if m := re.match(r"(deviceName|driverInfo)\s+= (.+)", s):
            g.setdefault(m.group(1), m.group(2).strip())
        elif m := re.match(r"(vendorID|deviceID)\s+= (0x[0-9a-f]+)", s):
            g.setdefault(m.group(1), m.group(2))
        elif m := re.match(r"pci(Domain|Bus|Device|Function)\s+= (\d+)", s):
            g["pci"].setdefault(m.group(1).lower(), int(m.group(2)))
        elif m := re.match(r"memoryHeaps\[(\d+)\]:", s):
            cur = g["heaps"].setdefault(int(m.group(1)), {"flags": []})
        elif m := re.match(r"memoryTypes\[(\d+)\]:", s):
            cur = g["types"].setdefault(int(m.group(1)), {})
        elif cur is not None and (m := re.match(r"(size|budget|usage)\s+= (\d+)", s)):
            cur[m.group(1)] = int(m.group(2))
        elif cur is not None and s.startswith("MEMORY_HEAP_"):
            cur["flags"].append(s)
        elif cur is not None and (m := re.match(r"heapIndex\s+= (\d+)", s)):
            cur["heap"] = int(m.group(1))
        elif cur is not None and (m := re.match(r"propertyFlags = (0x[0-9a-f]+)", s)):
            cur["flags"] = int(m.group(1), 16)
        elif s.startswith("VkPhysicalDeviceFeatures"):
            cur = None
    return gpus


def summarize(g):
    p = g["pci"]
    bdf = f"{p.get('domain', 0):04x}:{p.get('bus', 0):02x}:{p.get('device', 0):02x}.{p.get('function', 0)}"
    dlhv = sorted({t["heap"] for t in g["types"].values() if t.get("flags", 0) & (DL | HV) == DL | HV})
    heaps = [{"index": i, "size_mib": h.get("size", 0) >> 20, "budget_mib": h.get("budget", 0) >> 20,
              "usage_mib": h.get("usage", 0) >> 20,
              "device_local": "MEMORY_HEAP_DEVICE_LOCAL_BIT" in h["flags"]} for i, h in sorted(g["heaps"].items())]
    vram = max((h["size_mib"] for h in heaps if h["device_local"]), default=0)
    dlhv_mib = max((heaps[i]["size_mib"] for i in dlhv), default=0)
    return {"bdf": bdf, "gpu": g["gpu"], "name": g.get("deviceName"), "id": f"{g.get('vendorID')}:{g.get('deviceID')}",
            "driverInfo": g.get("driverInfo"), "heaps": heaps,
            "types": [{"index": i, "heap": t.get("heap"), "flags": f"{t.get('flags', 0):#06x}"}
                      for i, t in sorted(g["types"].items())],
            "dlhv_heaps": dlhv, "dlhv_heap_mib": dlhv_mib, "device_local_heap_mib": vram,
            "dlhv_covers_vram": bool(vram) and dlhv_mib >= vram}


def main():
    args = benchlib.common_args(__doc__).parse_args()
    rec = benchlib.start("vk_heaps", args)
    p = benchlib.sh("cd /tmp && vulkaninfo 2>/dev/null")
    want = {d["bdf"] for d in rec["devices"]}
    gpus = [summarize(g) for g in parse(p.stdout)]
    rec["result"] = {"vulkaninfo_rc": p.returncode,
                     "gpus": [g for g in gpus if g["bdf"] in want]}
    if not rec["result"]["gpus"]:
        rec["valid"] = False
        rec["invalid_reasons"].append("vulkaninfo reported none of the selected cards")
    benchlib.emit(rec)


if __name__ == "__main__":
    main()
