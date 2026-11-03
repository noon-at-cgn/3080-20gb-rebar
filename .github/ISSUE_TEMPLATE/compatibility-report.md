---
name: Compatibility report
about: Report whether geforce-bar1-resize enlarged BAR1 on your card (any Turing-or-later GeForce, worked or not)
title: "[compat] <card> <VRAM> vBIOS <version>"
labels: compatibility
---

<!-- SPDX-License-Identifier: MIT -->
<!-- Remove serial numbers, GPU UUIDs, hostnames and IP addresses before posting. -->

## Card

- Model and board vendor:
- VRAM:
- Memory-modded or stock:
- Boot display card (`boot_vga` = 1)? yes / no

## System

- Driver and version (proprietary / open kernel module / nouveau):
- Kernel and distribution:
- Motherboard / platform, Above-4G decoding and ReBAR settings in firmware:
- Bare metal or VM passthrough:
- Card on a CPU root port or behind a PCIe switch (`LAYOUT` setting, if behind a switch):

## `geforce-bar1-resize check --report` output (read-only)

```
paste the output of: sudo geforce-bar1-resize check --report <BDF>
(before installing: sudo scripts/geforce-bar1-resize check --report --vram <SIZE> <BDF>)
```

## After a boot with the service (optional)

- `journalctl -b -u geforce-bar1-resize`:
- BAR1 from `lspci -vv -s <BDF>` Region 1 (and `nvidia-smi -q -d MEMORY`):
- Reported VRAM before / after:
- `sudo geforce-bar1-resize driver-option --print` (is `RMForceStaticBar1=0` set for the card?):
- Any Xid or AER lines in `dmesg`:
- Console card only: did the console come back (nvidia-drm `fbdev=1` or a display server)?
- Did a workload run correctly afterwards? What did you run?

## Reboot / reset (if tried)

- BAR1 ≥ VRAM on every card after a cold boot and a warm reboot?
- After a device reset, did `geforce-bar1-resize repair` restore the capability?

## Notes
