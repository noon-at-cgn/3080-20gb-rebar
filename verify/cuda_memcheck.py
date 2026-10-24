#!/usr/bin/env python3
"""VRAM pattern check via the CUDA driver API (cuda_memcheck.c, built with gcc at run time; no CUDA
toolkit needed). Control for the BAR1 aperture test: it writes a unique per-word pattern into most
of free VRAM with DMA copies (cuMemcpyHtoD) and reads it back (cuMemcpyDtoH), never through BAR1.
A failure here is a memory fault; a pass here next to an aperture failure points at the aperture.

DRAINED CARD ONLY: refuses per card if any process holds /dev/nvidiaN or utilisation is not 0,
records kernel-log Xid/AER counts before and after, and SIGKILLs the run after --hard-timeout seconds."""
import time

import benchlib


def main():
    ap = benchlib.common_args(__doc__)
    ap.add_argument("--percent", type=int, default=90, help="share of free VRAM to test (default 90)")
    ap.add_argument("--chunk-mib", type=int, default=256)
    ap.add_argument("--hard-timeout", type=int, default=120, help="SIGKILL the run after this many seconds")
    args = ap.parse_args()
    rec = benchlib.start("cuda_memcheck", args)

    cards, ready = [], []
    for dev in rec["devices"]:
        bdf = dev["bdf"]
        pf = benchlib.sh_json(f"python3 - {bdf}", stdin=benchlib.PREFLIGHT)
        refuse = benchlib.preflight_refusals(pf)
        row = {"bdf": bdf, "preflight": pf}
        if refuse:
            row["refused"] = refuse
        else:
            ready.append(row)
        cards.append(row)

    build = None
    if ready:
        build, d = benchlib.build("cuda_memcheck")
        if d is None:
            for row in ready:
                row["refused"] = ["build failed: " + build.stderr.strip()[-300:]]
            ready = []
    if ready:
        try:
            for row in ready:
                bdf, t0 = row["bdf"], time.time() - 1
                row["kernel_events_before"] = benchlib.kernel_events(bdf)
                row["run"] = benchlib.run_binary(f"{d}/cuda_memcheck {bdf} {args.percent} {args.chunk_mib}",
                                                 args.hard_timeout)
                row["kernel_events_new"] = benchlib.kernel_events(bdf, t0)
        finally:
            benchlib.sh(f"rm -rf {d}")
    rec["result"] = {"ran": bool(ready), "cards": cards,
                     "build_warnings": (build.stderr.strip()[-300:] or None) if build else None}
    benchlib.emit(rec)


if __name__ == "__main__":
    main()
