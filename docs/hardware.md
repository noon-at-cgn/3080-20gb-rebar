<!-- SPDX-License-Identifier: MIT -->
# Hardware reports

One row per reported configuration, from the table `geforce-bar1-resize check --report` prints (paste it into the
*Compatibility report* issue template). A maintainer marks a row `verified` only for a full boot on their own
hardware, or for a report with the journal, `lspci -vv` Region 1 and no Xid or AER lines; other complete reports are
`reported`. The script's label table (`LABELS` in `scripts/geforce-bar1-resize`) lists only `verified` and `reported`
rows of this table.

| card | id/subsys | vBIOS | VRAM | route | n | BAR1 | driver | kernel | topology | console | outcome | issue | date |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| RTX 3080 20GB (memory-modded), 2 cards | `10de:2206/10de:146d` | 94.02.27.00.14 | 20480 MiB | `0x610` | 9 | 32768 MiB | 615.71.09 | Linux 7.x | direct | yes (one card) | verified | none | 2026-10 |
| RTX 3080 20GB (memory-modded), 2 cards, NVIDIA vGPU-KVM host with 4 SR-IOV VFs per card | `10de:2206/10de:146d` | 94.02.27.00.14 | 20480 MiB | `0x610` | 9 | 32768 MiB | 580.159.01 | Linux 7.0 | direct | yes (one card) | verified | none | 2026-11 |

Every other card is untested: the service enlarges it when the structural checks pass, and logs it as `(untested)`.
A card with no route to its full VRAM size (no GA102-style `0x610` block, for example a Blackwell-like layout, and a
capability that lists less than VRAM) gets the largest size it lists, if that is above its current BAR1, and the log
says `below VRAM`; report it with the BAR1 it ended at.

## The verified configuration in detail

| Measurement | Result |
|---|---|
| BAR1 | 256 → 32768 MiB |
| `0x610` / `0xbbc` | `00001001` → `00001c81` / `00001c00` → `000ffc00` |
| Pattern test through the aperture | default driver setting: about 10.2 GiB per card; `RMForceStaticBar1=0`: about 20.0 GiB (about 98 % of 20480 MiB); 0 mismatches |
| 512 MiB host-visible allocation | fails at 256 MiB BAR1, succeeds at 32 GiB |
| Xid / AER | 0 / 0 in all runs |
| Inference decode | about 78 tok/s at stock, about 80 tok/s at 32 GiB (no measurable difference) |
| CPU write through BAR1 | about 9.6 GB/s with a busy GPU (follows the PCIe link speed) |
| Persistence | applied at every boot; verified at warm reboots and cold power cycles, console card included |
| Host-visible allocation, `RMForceStaticBar1=0` (driver 615.71.09, static BAR1 off) | 19593 MiB and 19589 MiB on the two cards (about 19.6 GB) |
| SR-IOV vGPU host (NVIDIA vGPU-KVM driver 580.159.01, 4 VFs per card) | BAR1 Total 32768 MiB, BAR1 Used 1 MiB; the VFs and the vGPU types are unaffected; the resize runs after the SR-IOV preparation and before the driver; no Xid, AER or DMAR lines |
| Cards | each directly on a CPU root port (Linux 7.0 class kernel); the display card is included |

Test commands: `results/README.md`.

## What only real hardware can show

Emulated hardware covers the script's decisions, the verification and restore paths and the layout module
([testing.md](testing.md)), but not:

- whether `0x610` latches and widens the capability on each family (Turing, GA103-GA107, Ada, A-series);
- that BAR1 decode follows the new size, and that the driver initialises with a large BAR1 on that family, with and
  without `RMForceStaticBar1=0`;
- the console handover to `nvidia-drm` on a real GOP framebuffer, and int10h/CSM behaviour on unload;
- real PCIe switches, firmware e820 reservations and 64-bit MMIO limits, and a device reset followed by `repair`.

## Help wanted: RTX 4090 / 4090D 48GB (64 GiB BAR1)

The memory-modded 48GB 4090 and 4090D cap BAR1 at 32 GiB, less than their VRAM. Their vBIOS uses the same `0x610`
register as the 3080, and NVIDIA's own 48GB AD102 cards (L40S, RTX 6000 Ada) ship with 64 GiB. Whether AD102 accepts
the write from the host is untested. If the driver has seen the card once (or `size=64G` is set for it),
`geforce-bar1-resize` plans `0x610 VAL=10` and a 64 GiB BAR1 for it; `sudo geforce-bar1-resize check --report` shows
the plan without writing anything.

To try it by hand instead, first make sure the card passes the structural checks:
`sudo geforce-bar1-resize check --vram 48G <BDF>` (`scripts/geforce-bar1-resize` in this repository if it is not
installed) must show `ok` for S1 to S6 and `PLAN    arm 0x610 VAL=10, resize to 65536 MiB`. Then, as root, with the
card idle and not driving the display (a power-off undoes it; nothing is flashed), arm and resize while the driver is
unbound. Bind the driver again only once BAR1 has its new size, or after disarming: never bind it to a card that is
armed but not resized.

```sh
BDF=0000:01:00.0                                  # your card, from lspci -Dnn -d 10de::0300
lspci -vv -s $BDF | grep 'Region 1'               # note the stock size: 256M is index 8, 32G is index 15
setpci -s $BDF 0x60c.L 0x610.L 0xbbc.L 0xdcc.L
echo $BDF > /sys/bus/pci/drivers/nvidia/unbind
setpci -s $BDF 0x610.L=00000d00:00000f80          # arm: size field 10 = 64 GiB
setpci -s $BDF 0x610.L 0xbbc.L                    # compare with the first read
```

Go on only if `0x610` reads as before except bits 11:7, now enable plus 10 (`0xd00`), and `0xbbc` lists every size it
listed before plus bit 20 (64 GiB): for example `00001001` and `000ffc00` before give `00001d01 001ffc00`. Otherwise
disarm, rebind and report the output:

```sh
setpci -s $BDF 0x610.L=00000000:00000f80          # disarm: bits 11:7 back to 0
echo $BDF > /sys/bus/pci/drivers/nvidia/bind
```

If both read as expected, resize, with the driver still unbound (also untested):

```sh
echo 16 > /sys/bus/pci/devices/$BDF/resource1_resize   # 16 = 64 GiB; "No space left" = address window too small
lspci -vv -s $BDF | grep 'Region 1'                     # expect [size=64G]
```

If Region 1 shows `[size=64G]`, bind the driver and check:

```sh
echo $BDF > /sys/bus/pci/drivers/nvidia/bind
nvidia-smi -q -d MEMORY | grep -A1 BAR1                  # expect Total 65536 MiB
```

Otherwise do not bind yet: if Region 1 no longer has its stock size, write the stock index back first
(`echo 8 > /sys/bus/pci/devices/$BDF/resource1_resize` for 256M), then disarm and bind as above.

The slot needs room for a 64 GiB-aligned BAR1 in the 64-bit address space (Above 4G Decoding on). Open an issue with
all the output, `lspci -nn`, the vBIOS version and the board, whether it worked or not.
