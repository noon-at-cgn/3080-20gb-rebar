# verify/

Checks for a working 32 GiB BAR1. Run as root, once at stock and once armed, and compare with the table below.

| Script | Checks | Writes VRAM? |
|---|---|---|
| `bar1_report.py` | BAR1 total/used from `nvidia-smi` and NVML | no |
| `vk_heaps.py` | Vulkan heap that carries the DEVICE_LOCAL\|HOST_VISIBLE memory type, and its size | no |
| `vk_bar_verify.py` | Pattern test through the aperture: CPU writes through the mapping, GPU reads back, and the reverse | yes |
| `cuda_memcheck.py` | Control: the same pattern by DMA, never through BAR1 | yes |

Requirements: root, Python 3.8+, `gcc`, `nvidia-smi`, `journalctl`; `vulkaninfo` and the NVIDIA Vulkan driver for
the Vulkan scripts; `libcuda.so.1` and `libnvidia-ml.so.1` (shipped with the driver). No SDK or toolkit is needed.

`vk_bar_verify.py` and `cuda_memcheck.py` refuse a card that any process holds or that is busy: stop every GPU
user first (`fuser -v /dev/nvidia*` must print nothing).

## Usage

```sh
cd verify
B=0000:01:00.0   # your card; use --expect-bar1 256M at stock
sudo python3 bar1_report.py   --bdf $B --expect-bar1 32G | jq '.valid, .result.cards[]'
sudo python3 vk_heaps.py      --bdf $B --expect-bar1 32G | jq '.result.gpus[] | {dlhv_heaps, dlhv_heap_mib, dlhv_covers_vram}'
sudo python3 vk_bar_verify.py --bdf $B --expect-bar1 32G --reserve-mib 0 | jq '.result.run | {allocated_mib, stop_reason, mismatched_words, verdict}'
sudo python3 cuda_memcheck.py --bdf $B --expect-bar1 32G | jq '.result.cards[].run | {tested_mib, mismatched_words, verdict}'
```

Each record starts with a header (`cfg_610`, `cfg_bbc`, `region1_mib`, `bar1_total_mib`, …) and is flagged
`"valid": false` if BAR1 does not match `--expect-bar1`.

## Expected output

Values from a 20 GiB card; sizes scale with VRAM. "Armed, lifted" is armed with `RMForceStaticBar1=0`.

| Field | Stock | Armed, driver default | Armed, lifted |
|---|---|---|---|
| `cfg_610` / `cfg_bbc` | `00001001` / `00001c00` | `00001c81` / `000ffc00` | same as armed |
| `region1_mib` / `bar1_total_mib` | 256 / 256 | 32768 / 32768 | 32768 / 32768 |
| `vk_heaps`: `dlhv_heap_mib` / `dlhv_covers_vram` | 246 / false | 20480 / true | 20480 / true |
| `vk_bar_verify` (`--reserve-mib 0`): `allocated_mib` | about 240 (heap size) | about 10200 (about half of VRAM) | about 20050 (about 98 % of VRAM) |
| `vk_bar_verify`: `stop_reason` / `mismatched_words` / `verdict` | `alloc_failed` / 0 / true | `alloc_failed` / 0 / true | `alloc_failed` / 0 / true |
| `cuda_memcheck`: `tested_mib` / `mismatched_words` | 17664 / 0 | 17664 / 0 | 17664 / 0 |
| `kernel_events_new`: Xid / AER | 0 / 0 | 0 / 0 | 0 / 0 |

Any `mismatched_words` above 0, `verdict` false, a `killed` field, or a new Xid/AER line is a failure. A clean
`cuda_memcheck` next to a failing `vk_bar_verify` points at the aperture; a failing `cuda_memcheck` at the memory.
