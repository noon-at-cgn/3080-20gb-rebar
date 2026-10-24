# Results

Two memory-modded RTX 3080 20GB cards (`10de:2206`, vBIOS 94.02.27.00.14), NVIDIA driver 615.71.09, Linux 7.x.
Stock is BAR1 256 MiB; armed is BAR1 32 GiB.

| Measurement | Result |
|---|---|
| BAR1 | 256 → 32768 MiB |
| `0x610` | `00001001` → `00001c81` |
| `0xbbc` | `00001c00` → `000ffc00` |
| Pattern test through the aperture | default driver setting: about 10.2 GiB per card; `RMForceStaticBar1=0`: about 20.0 GiB (about 98 % of 20480 MiB); 0 mismatches |
| 512 MiB host-visible allocation | fails at 256 MiB BAR1, succeeds at 32 GiB |
| Xid / AER | 0 / 0 in all runs |
| Inference decode | about 78 tok/s at stock, about 80 tok/s at 32 GiB (no measurable difference) |
| CPU write through BAR1 | about 9.6 GB/s with a busy GPU (follows the PCIe link speed) |
| Persistence | re-armed at every boot; verified at warm reboots and cold power cycles |

Test commands (as root, every GPU user stopped; at stock use `--expect-bar1 256M`):

```sh
python3 verify/bar1_report.py   --bdf <BDF> --expect-bar1 32G
python3 verify/vk_bar_verify.py --bdf <BDF> --expect-bar1 32G --reserve-mib 0
python3 verify/cuda_memcheck.py --bdf <BDF> --expect-bar1 32G
```
