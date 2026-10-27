# 3080-20gb-rebar: 32 GiB BAR1 on the memory-modded RTX 3080 20GB without flashing the vBIOS

For the memory-modded RTX 3080 20GB. On GA102, PCI config dword `0x610` holds a frame-buffer size override.
Writing `00001c81` to it makes the GPU advertise a 32 GiB BAR1 (`0xbbc` reads `000ffc00`), and the kernel's sysfs
ReBAR interface then resizes BAR1 to 32 GiB before the NVIDIA driver binds. Nothing is flashed to the GPU. The
change is volatile (gone at power-off), so a small systemd service re-applies it at every boot. Reported VRAM is
unchanged.

> **Have a memory-modded RTX 4090 / 4090D 48GB and want a 64 GiB BAR1?** This method may work for you too; see
> [Help wanted: RTX 4090 / 4090D 48GB](#help-wanted-rtx-4090--4090d-48gb-64-gib-bar1).

## Disclaimer

**Use at your own risk.** This project is provided as is, without warranty of any kind, under the MIT licence
(see `LICENSE`). I am not responsible or liable for any damage, data loss, hardware
failure, instability, downtime or voided warranty that results from using it.

## Tested on

- The target: two memory-modded RTX 3080 20GB, `10de:2206`, subsystem `10de:146d`, vBIOS `94.02.27.00.14`
- Any number of cards, each chosen by its full PCI address (`0000:01:00.0`); tested with two. Each card needs
  32 GiB of 64-bit address space under its bridge.
- NVIDIA proprietary driver 615.71.09
- Linux 7.x with systemd

Other GA102 cards could work, since NVIDIA publishes the same register definitions for them, but they are
untested. Stock cards with NVIDIA's own ReBAR vBIOS update do not need this.

## Requirements

- Root, `pciutils` (`setpci`, `lspci`), systemd.
- A kernel that exposes `/sys/bus/pci/devices/<BDF>/resource1_resize`.
- Above-4G decoding and enough 64-bit MMIO space for a 32 GiB BAR per card.
- The NVIDIA driver loads from the root file system, after the service runs (not from the initramfs).
- A machine where a GPU or host hang is acceptable while you try it.

## How it works

The CPU reaches a GPU's memory through a PCI memory window called BAR1. A stock RTX 3080 20GB gets a 256 MiB
window, so only a small slice of the 20 GB is visible at any moment and larger host-visible allocations fail.
A bigger window is normally called Resizable BAR, and it has traditionally needed a new vBIOS, because the
vBIOS decides which window sizes the card offers. Flashing is risky, and NVIDIA does not publish a ReBAR vBIOS
for these memory-modded boards. This project skips the vBIOS: the operating system asks the card for the larger
window at boot, in three steps.

1. **Make the card offer 32 GiB.** GA102 has a frame-buffer size override in PCI config space at `0x610`. Writing
   `00001c81` sets its enable bit (bit 11) and a size field of 9 (bits 10:7), meaning 64 MiB << 9 = 32 GiB. The
   card's Resizable BAR capability (`0xbbc`) then lists sizes up to 32 GiB instead of 256 MiB (`00001c00` becomes
   `000ffc00`). This is a config write, not a flash write. Nothing is stored on the card, so a power-off or reboot
   returns it to stock, and the boot service writes it again.
2. **Resize BAR1 while no driver is attached.** The kernel can only move and resize a BAR when no driver owns
   the device, so the service runs before the NVIDIA driver loads. It writes size index 15 (1 MiB << 15 = 32 GiB)
   to the card's `resource1_resize` file in sysfs, and the kernel re-assigns BAR1 inside the 32 GiB 64-bit
   window. That needs Above-4G decoding and enough 64-bit MMIO space under the card's PCIe bridge.
3. **Stop the driver from over-reserving it.** With a large BAR the NVIDIA driver switches to "static BAR1": it
   maps VRAM into BAR1 up front and counts host-visible memory twice against it, so only about half of VRAM
   (about 10 GiB) can be allocated for CPU access. Setting `RMForceStaticBar1=0` for the card (installed by
   `install.sh`) returns to on-demand mapping, and about 98 % of VRAM becomes reachable.

The vBIOS and flash are never written, and the card still reports 20 GB. What changes is how much of that memory
the CPU can reach directly.

## Quick start

```sh
lspci -Dnn -d 10de::0300                          # list NVIDIA GPUs with their IDs, e.g. 0000:01:00.0 ... [10de:2206]
sudo scripts/rebar-check.sh --vram 20G            # read-only; must report that the preconditions hold
sudo ./install.sh --bdfs "<address>" --enable     # writes /etc/rebar-arm.conf, the script, unit and driver option
sudo reboot
```

Use the address of your own card from the first command; the ID in brackets should match *Tested on*. Without
`--bdfs`, `install.sh` lists the cards it finds and asks which to arm.

**Several cards:** separate the addresses with spaces inside one pair of quotes, not commas:
`--bdfs "0000:01:00.0 0000:02:00.0"`. `/etc/rebar-arm.conf` (`REBAR_BDFS`) uses the same format. The driver line in
the next section uses semicolons instead (`pci=<address>;RMForceStaticBar1=0;` per card); `install.sh` writes it.

For the verified card the installer also sets the NVIDIA driver option that makes all of VRAM reachable through
BAR1 (next section). `install.sh` leaves out the card that drives the display unless you pass
`--include-console`; arm that card by hand once first (*Manual procedure*). `./install.sh --help` lists the other
options (`--dry-run`, `--root DIR`, `--no-lift-ceiling`).

## Verify

```sh
journalctl -b -u rebar-arm                     # <BDF> armed and resized to 32768 MiB
sudo setpci -s <BDF> 0x610.L 0xbbc.L           # 00001c81, 000ffc00
lspci -vv -s <BDF> | grep "Region 1"           # [size=32G]
nvidia-smi -q -d MEMORY | grep -A1 BAR1        # Total 32768 MiB
```

Deeper checks (pattern test through the aperture, CUDA control) are in `verify/README.md`.

## Driver option: all of VRAM through BAR1

With the driver's default (static BAR1), only about half of VRAM is reachable as host-visible memory. For the
verified card `install.sh` writes `/etc/modprobe.d/zz-nvidia-static-bar1.conf`, one entry per armed card:

```
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:01:00.0;RMForceStaticBar1=0;pci=0000:02:00.0;RMForceStaticBar1=0;"
```

| Driver setting | Host-visible VRAM reachable per card (20480 MiB) |
|---|---|
| default | about 10.2 GiB |
| `RMForceStaticBar1=0` | about 20.0 GiB (about 98 %) |

- **Rule:** list every card in that one line; never also set the global `NVreg_RegistryDwords` option.
- **Turn it off:** install with `--no-lift-ceiling`, or delete the file and reboot. Other cards get it only with
  `--lift-ceiling`.
- **Caveat:** nvidia-smi *BAR1 Used* no longer tracks VRAM use.

## Next step: GPU-to-GPU P2P

With the 32 GiB BAR1 and `RMForceStaticBar1=0` from this repo in place, two or more of these cards can copy directly
to each other (peer-to-peer) with the patched NVIDIA open kernel modules in
[3080-20g-p2p](https://github.com/noon-at-cgn/3080-20g-p2p). On the tested pair it measured 10.27 GB/s one way
(5.78 GB/s without P2P) and made vLLM tensor-parallel prefill 6-10 % faster.

## Results

| Measurement | Result |
|---|---|
| BAR1 | 256 → 32768 MiB |
| `0x610` / `0xbbc` | `00001001` → `00001c81` / `00001c00` → `000ffc00` |
| Pattern test through the aperture | default driver setting: about 10.2 GiB per card; `RMForceStaticBar1=0`: about 20.0 GiB (about 98 % of 20480 MiB); 0 mismatches |
| 512 MiB host-visible allocation | fails at 256 MiB BAR1, succeeds at 32 GiB |
| Xid / AER | 0 / 0 in all runs |
| Inference decode | about 78 tok/s at stock, about 80 tok/s at 32 GiB (no measurable difference) |
| CPU write through BAR1 | about 9.6 GB/s with a busy GPU (follows the PCIe link speed) |
| Persistence | re-armed at every boot; verified at warm reboots and cold power cycles |

Test commands: `results/README.md`.

## Manual procedure (per card, as root)

1. Stop every GPU user; `fuser -v /dev/nvidia*` must print nothing.
2. If the card drives the display (`boot_vga` is `1`), detach the console or the unbind hangs:
   `echo 0 > /sys/class/vtconsole/vtcon1/bind` (the vtcon whose `name` is `(M) frame buffer device`).
3. `echo $BDF > /sys/bus/pci/drivers/nvidia/unbind`
4. `setpci -s $BDF 0x610.L=00000c80:00000f80` (bits 11:7 only), then check `0x610` = `00001c81` and `0xbbc` = `000ffc00`.
5. `echo 15 > /sys/bus/pci/devices/$BDF/resource1_resize` (15 is the size index for 32 GiB, not bytes).
6. `echo $BDF > /sys/bus/pci/drivers/nvidia/bind`, then reattach the console if you detached it:
   `echo 1 > /sys/class/vtconsole/vtcon1/bind`.

**Rollback without a reboot:** steps 1-3, then shrink first, `echo 8 > /sys/bus/pci/devices/$BDF/resource1_resize`,
and only then `setpci -s $BDF 0x610.L=00001001:00000f80`; rebind and reattach the console. Do not disarm `0x610`
while BAR1 is still 32 GiB.

## Uninstall and rollback

```sh
sudo ./uninstall.sh   # or --dry-run
sudo reboot           # BAR1 is back to 256 MiB after the reboot
```

`uninstall.sh` disables the service and moves its files, including the driver option file, into
`/var/backups/rebar-arm/`. Until the reboot, BAR1 stays at 32 GiB; to undo it live, use the rollback above.
After a GPU reset (FLR) `0x610` may be cleared while BAR1 stays at 32 GiB; `sudo rebar-arm.sh --repair` re-arms it
(manual command, nothing runs it automatically). A real FLR has not been tested: `--repair` has only been run
against stand-ins and on healthy cards.

## Troubleshooting

| Problem | Fix |
|---|---|
| `echo ... > resource1_resize` fails with `EINVAL` | Write the size index, not bytes: `15` for 32 GiB. |
| `0xbbc` does not change to `000ffc00` after arming | Run `scripts/rebar-check.sh`. If `0x60c` bit 11 is set and it still does not widen, the card may not support it; please report it. |
| Journal says `already bound to nvidia, skip`, BAR1 is 256 MiB | The driver bound first. Enable the unit and keep the NVIDIA driver out of the initramfs. |
| Unbind hangs or the screen goes blank on the display card | Detach the console first (step 2). `install.sh` leaves this card out unless `--include-console`. |
| Host-visible allocations fail at about half of VRAM | The driver option is missing: check `/etc/modprobe.d/zz-nvidia-static-bar1.conf` lists the card (installed by default for the verified card, `--lift-ceiling` for others), then reboot. |
| CPU writes through BAR1 drop to 5 or 2.4 GB/s on an idle GPU | The idle GPU lowers its PCIe link speed. With persistence mode on (`nvidia-smi -pm 1`), lock the memory clock around large uploads: `nvidia-smi -i <BDF> -lmc <max>,<max>`, then `-rmc`. |

## Reporting compatibility

Run `sudo scripts/rebar-check.sh --vram <SIZE>` (read-only) and open an issue with the *Compatibility report*
template, including its output.

### Help wanted: RTX 4090 / 4090D 48GB (64 GiB BAR1)

The memory-modded 48GB 4090 and 4090D cap BAR1 at 32 GiB, less than their VRAM. Their vBIOS uses the same `0x610`
register as the 3080, and NVIDIA's own 48GB AD102 cards (L40S, RTX 6000 Ada) ship with 64 GiB. Whether AD102
accepts the write from the host is untested. If you have one on Linux, run this as root with the card idle and not
driving the display (a power-off undoes it; nothing is flashed):

```sh
BDF=0000:01:00.0                                  # your card, from lspci -Dnn -d 10de::0300
setpci -s $BDF 0x60c.L 0x610.L 0xbbc.L 0xdcc.L
echo $BDF > /sys/bus/pci/drivers/nvidia/unbind
setpci -s $BDF 0x610.L=00000d00:00000f80          # size field 10 = 64 GiB
setpci -s $BDF 0x610.L 0xbbc.L                    # works if: 00001d01 001ffc00
echo $BDF > /sys/bus/pci/drivers/nvidia/bind
```

Open an issue with all the output, `lspci -nn`, the vBIOS version and the board.

## Licence

MIT, see `LICENSE`.
