---
name: Compatibility report
about: Report whether the BAR1 size override works on your card
title: "[compat] <card> <VRAM> vBIOS <version>"
labels: compatibility
---

<!-- Remove serial numbers, GPU UUIDs, hostnames and IP addresses before posting. -->

## Card

- Model and board vendor:
- VRAM:
- Device id / subsystem id (`lspci -nn -d 10de:` and `cat /sys/bus/pci/devices/<BDF>/subsystem_*`):
- vBIOS version:
- Memory-modded or stock:
- Boot display card (`boot_vga` = 1)? yes / no

## System

- Driver and version (proprietary / open kernel module / nouveau):
- Kernel and distribution:
- Motherboard / platform, Above-4G decoding and ReBAR settings in firmware:
- Bare metal or VM passthrough:

## `rebar-check.sh` output (read-only)

```
paste the output of: sudo scripts/rebar-check.sh --vram <SIZE> <BDF>
```

## Did you arm it? (optional)

- n used:
- `0x610` and `0xbbc` before / after:
- `resource1_resize` before / after:
- BAR1 from `nvidia-smi -q -d MEMORY` and `lspci -vv` Region 1:
- Reported VRAM before / after:
- Any Xid or AER lines in `dmesg`:
- Did a workload run correctly afterwards? What did you run?

## Reboot / reset (if tried)

- Boot service re-armed it after reboot? Lines from `journalctl -b -u rebar-arm`:
- After a device reset, did `rebar-arm.sh --repair` restore `0xbbc`?

## Notes
