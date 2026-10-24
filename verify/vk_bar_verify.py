#!/usr/bin/env python3
"""Memtest-style pattern check of the DEVICE_LOCAL|HOST_VISIBLE (BAR1-backed) memory type
(vk_bar_verify.c, built with gcc at run time; no Vulkan SDK needed). No config writes.

Allocates --chunk-mib chunks (halving down to 1 MiB on failure) until free VRAM minus --reserve-mib is
used or allocation fails. Per chunk the CPU writes pattern A through the mapping and the GPU copies the
chunk into host memory, where every word is compared; then the GPU writes pattern B into the chunk and
the CPU reads 4 KiB per 64 MiB of it back through the mapping. A final GPU readback compares every chunk
with B again (catches a later chunk aliasing onto an earlier one). Each 64-bit word is unique per run
(chunk, 4 KiB block, word index, seed).

Observed on two RTX 3080 20GB cards (heap 0, 20480 MiB at 32 GiB BAR1): with the driver's default static
BAR1, "alloc_failed" at 10208-10218 MiB; with RMForceStaticBar1=0 and --reserve-mib 0, "alloc_failed" at
20049-20068 MiB (VRAM full). At 256 MiB BAR1 "alloc_failed" at 211-243 MiB (heap 2, 246 MiB).
`mismatched_words` 0 in every state.

DRAINED CARD ONLY: refuses per card unless no process holds /dev/nvidiaN and utilisation is 0 in every
sample; records kernel-log Xid/AER counts before and after (per chunk too, from /dev/kmsg); the binary
stops at the first new Xid; a 16 MiB warm-up runs first; each run is SIGKILLed after --hard-timeout.
Prints one JSON line per card."""
import os
import time

import benchlib


def main():
    ap = benchlib.common_args(__doc__)
    ap.add_argument("--chunk-mib", type=int, default=1024, help="allocation size per chunk, default 1024")
    ap.add_argument("--reserve-mib", type=int, default=1024, help="leave this much VRAM free, default 1024")
    ap.add_argument("--max-total-mib", type=int, help="cap on the total allocated (default: free VRAM - reserve)")
    ap.add_argument("--seed", type=lambda s: int(s, 0), help="pattern seed (default random, recorded)")
    ap.add_argument("--hard-timeout", type=int, default=240, help="SIGKILL each run after this many seconds")
    args = ap.parse_args()
    rec = benchlib.start("vk_bar_verify", args)
    seed = args.seed if args.seed is not None else int.from_bytes(os.urandom(8), "little")

    cards, ready = [], []
    for dev in rec["devices"]:
        bdf = dev["bdf"]
        pf = benchlib.sh_json(f"python3 - {bdf}", stdin=benchlib.PREFLIGHT)
        pf["kernel_events_boot"] = benchlib.kernel_events(bdf)
        limit = pf["vram_free_mib"] - args.reserve_mib
        if args.max_total_mib is not None:
            limit = min(limit, args.max_total_mib)
        refuse = benchlib.preflight_refusals(pf)
        if limit < 16:
            refuse.append(f"free {pf['vram_free_mib']} MiB - reserve {args.reserve_mib} MiB leaves {limit} MiB")
        row = {"bdf": bdf, "preflight": pf, "limit_mib": limit, "seed": f"{seed:#018x}"}
        if refuse:
            row["refused"] = refuse
        else:
            ready.append(row)
        cards.append(row)

    build = None
    if ready:
        build, d = benchlib.build("vk_bar_verify")
        if d is None:
            for row in ready:
                row["refused"] = ["build failed: " + build.stderr.strip()[-300:]]
            ready = []
    if ready:
        exe = f"{d}/vk_bar_verify"
        try:
            for row in ready:
                bdf, t0 = row["bdf"], time.time() - 1
                parent = os.path.basename(os.path.dirname(os.path.realpath(f"/sys/bus/pci/devices/{bdf}")))
                cmd = f"{exe} {bdf} {{chunk}} {{limit}} {seed:#x} {parent}"
                row["warmup"] = benchlib.run_binary(cmd.format(chunk=16, limit=16), args.hard_timeout)
                ev = benchlib.kernel_events(bdf, t0)
                if ev["xid_any"] or ev["aer"] or "killed" in row["warmup"]:
                    row["stopped"] = {"after": "warmup", **ev}
                    break
                row["run"] = benchlib.run_binary(cmd.format(chunk=args.chunk_mib, limit=row["limit_mib"]),
                                                 args.hard_timeout)
                ev = benchlib.kernel_events(bdf, t0)
                row["kernel_events_new"] = ev
                if ev["xid_any"] or ev["aer"] or "killed" in row["run"]:
                    row["stopped"] = {"after": "run", **ev}
                    break
        finally:
            benchlib.sh(f"rm -rf {d}")
        for row in ready:
            if "warmup" not in row:
                row["skipped"] = "stopped after an earlier card"

    warnings = (build.stderr.strip()[-300:] or None) if build else None
    if not cards:
        rec["result"] = {"ran": False, "cards": []}
        benchlib.emit(rec)
    for row in cards:
        bdf = row["bdf"]
        reasons = [r for r in rec["invalid_reasons"] if r.startswith(bdf)]
        benchlib.emit({**rec, "devices": [d for d in rec["devices"] if d["bdf"] == bdf],
                       "valid": None if rec["expect_bar1_mib"] is None else not reasons,
                       "invalid_reasons": reasons,
                       "result": {"ran": "run" in row, **row, "build_warnings": warnings}})


if __name__ == "__main__":
    main()
