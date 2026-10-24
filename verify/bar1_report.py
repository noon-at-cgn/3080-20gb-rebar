#!/usr/bin/env python3
"""BAR1 total/used/free per card from nvidia-smi and NVML (ctypes). Read-only."""
import benchlib

NVML = r'''
import ctypes, json, sys
class Bar1(ctypes.Structure):
    _fields_ = [("total", ctypes.c_ulonglong), ("free", ctypes.c_ulonglong), ("used", ctypes.c_ulonglong)]
class Mem(ctypes.Structure):
    _fields_ = [("total", ctypes.c_ulonglong), ("free", ctypes.c_ulonglong), ("used", ctypes.c_ulonglong)]
lib = ctypes.CDLL("libnvidia-ml.so.1")
out = {}
rc = lib.nvmlInit_v2()
if rc:
    print(json.dumps({"error": f"nvmlInit_v2 rc={rc}"})); sys.exit()
ver = ctypes.create_string_buffer(96)
lib.nvmlSystemGetDriverVersion(ver, 96)
for bdf in sys.argv[1:]:
    h = ctypes.c_void_p()
    rc = lib.nvmlDeviceGetHandleByPciBusId_v2(("0000" + bdf).encode(), ctypes.byref(h))
    if rc:
        out[bdf] = {"error": f"handle rc={rc}"}; continue
    b, m = Bar1(), Mem()
    rb = lib.nvmlDeviceGetBAR1MemoryInfo(h, ctypes.byref(b))
    rm = lib.nvmlDeviceGetMemoryInfo(h, ctypes.byref(m))
    out[bdf] = {"bar1_total_bytes": b.total, "bar1_used_bytes": b.used, "bar1_free_bytes": b.free,
                "rc_bar1": rb, "vram_total_bytes": m.total, "vram_used_bytes": m.used, "rc_mem": rm}
lib.nvmlShutdown()
print(json.dumps({"nvml_driver": ver.value.decode(), "devices": out}))
'''


def main():
    args = benchlib.common_args(__doc__).parse_args()
    rec = benchlib.start("bar1_report", args)
    bdfs = [d["bdf"] for d in rec["devices"]]
    nvml = benchlib.sh_json("python3 - " + " ".join(bdfs), stdin=NVML)
    rows = []
    for d in rec["devices"]:
        n = nvml.get("devices", {}).get(d["bdf"], {})
        row = {"bdf": d["bdf"], "nvsmi_bar1_total_mib": d["bar1_total_mib"],
               "nvsmi_bar1_used_mib": d["bar1_used_mib"], **n}
        if "bar1_total_bytes" in n:
            row["nvml_bar1_total_mib"] = n["bar1_total_bytes"] >> 20
            row["nvml_bar1_used_mib"] = n["bar1_used_bytes"] >> 20
            row["nvml_matches_nvsmi"] = row["nvml_bar1_total_mib"] == d["bar1_total_mib"]
        rows.append(row)
    rec["result"] = {"nvml_driver": nvml.get("nvml_driver"), "error": nvml.get("error"), "cards": rows}
    benchlib.emit(rec)


if __name__ == "__main__":
    main()
