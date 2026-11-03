<!-- SPDX-License-Identifier: MIT -->
# geforce-bar1-resize: BAR1 at least as large as VRAM on GeForce cards, without flashing

On Turing and later GeForce cards, a boot service gives every card a BAR1 (the CPU's window into VRAM) at least as
large as its VRAM, before the NVIDIA driver loads. Where the card's Resizable BAR capability already lists that size,
it only resizes; where the list is too short (memory mods, capped vBIOS) and the card's config space has the known
layout, it first sets the frame-buffer size override in PCI config space (`0x610`), the way NVIDIA's own ReBAR firmware
does. A card with neither route gets the largest size its capability lists, logged as below VRAM. Nothing is flashed:
the change is volatile, gone at power-off, and the service applies it again at every boot. Reported VRAM is unchanged.

## Disclaimer

**Use at your own risk.** This project is provided as is, without warranty of any kind, under the MIT licence
(see `LICENSE`). I am not responsible or liable for any damage, data loss, hardware
failure, instability, downtime or voided warranty that results from using it.

## Status

| | Cards | Result |
|---|---|---|
| Verified | RTX 3080 20GB (memory-modded), `10de:2206` subsystem `10de:146d` | 32 GiB BAR1 via `0x610`, two cards on CPU root ports, display card included, warm and cold boots; on driver 615.71.09 and on the NVIDIA vGPU-KVM host driver 580.159.01 with SR-IOV VFs |
| Untested | every other Turing-or-later GeForce card | enlarged automatically: resized where the card already lists the size, through `0x610` once the structural checks pass, otherwise to the largest size it lists; every write verified and undone on failure; the log marks the card `(untested)` |

Reports and their outcomes: [docs/hardware.md](docs/hardware.md). The boot service works alongside an NVIDIA vGPU host
with SR-IOV virtual functions (for example [geforce-sriov](https://github.com/noon-at-cgn/geforce-sriov)): it runs
after the host's SR-IOV preparation unit, and the VFs and vGPU types are unaffected. Cards behind PCIe switches are
experimental and off by default ([docs/pcie-switches.md](docs/pcie-switches.md)). What was tested, and how to run the
tests: [docs/testing.md](docs/testing.md).

## Requirements

- Root, `pciutils` (`setpci`, `lspci`), bash and systemd.
- A kernel that exposes `/sys/bus/pci/devices/<BDF>/resource1_resize`.
- Above-4G decoding and room in the 64-bit address space for each card's new BAR1 (32 GiB for a 20 GB card).
- The NVIDIA driver loads from the root file system, after the service runs (not from the initramfs).
- The card's VRAM size: recorded automatically once the NVIDIA driver has seen the card, or `size=` in the config.
- A machine where a GPU or host hang is acceptable while you try it.

## Quick start

```sh
sudo scripts/geforce-bar1-resize check --vram 20G   # read-only: per card the checks, the label and the plan
sudo ./install.sh --enable                          # prints the plan and asks
sudo reboot
```

`--vram` is your card's VRAM; once installed, `check` takes it from the record. `install.sh` reads VRAM from the
loaded NVIDIA driver; if the driver was not loaded, the first boot records it and the next boot enlarges BAR1.
`sudo ./install.sh --dry-run` shows everything it would do and changes nothing. The card that drives the console is
included: its console is blank from the resize at boot until `nvidia-drm` (`fbdev=1`) or a display server takes over;
`--console skip` leaves that card stock ([docs/console.md](docs/console.md)).

## Verify

```sh
journalctl -b -u geforce-bar1-resize  # "<BDF> armed and resized to 32768 MiB", or "... (resize only, 0x610 untouched)"
lspci -vv -s <BDF> | grep "Region 1"  # [size=32G]: the real BAR1 size, the check that counts
sudo geforce-bar1-resize check <BDF>  # PLAN    none: BAR1 already 32768 MiB, skip
```

Do not rely on `nvidia-smi` for this: its *BAR1 Total* follows the size the card advertises, so it can show 32768 MiB
while the real BAR1 is still 256 MiB. Deeper checks: `verify/README.md`.

## Configuration

`/etc/geforce-bar1-resize.conf` (written by `install.sh`): `CARDS` (default: every NVIDIA display function with a
Resizable BAR entry for BAR1, GeForce or not), `EXCLUDE`, `SIZE`, `ROUTE`, `LAYOUT`, `DRIVER_OPTION`, `CONSOLE`, and
per-card `CARD[]` entries keyed by address or id. `install.sh` sets the same keys from the command line (`--cards`,
`--exclude`, `--size`, `--route`, `--layout`, `--driver-option`, `--console`) and leaves the rest of the file alone;
`sudo geforce-bar1-resize plan` logs what the next boot would do. The console card is included by default
([docs/console.md](docs/console.md)).

The driver option `RMForceStaticBar1=0` makes all of VRAM reachable through BAR1. By default it is written only for
cards enlarged through `0x610`. Cards resized without it keep the driver's static BAR1, which some P2P setups need
(stock RTX 50 BAR1 P2P, static-BAR1 P2P patches), unless `driver_option=on`
([docs/driver-option.md](docs/driver-option.md)). All keys: [docs/configuration.md](docs/configuration.md); how it
works: [docs/how-it-works.md](docs/how-it-works.md).

## Upgrading from 3080-20gb-rebar

Run `sudo ./install.sh` from this repository. It migrates the old install: the same cards and size, your driver keys
(such as `RMDynBar1P2PEnable=0`), the unit's drop-ins and its enabled state; the old files go to
`/var/backups/geforce-bar1-resize/`. If it is interrupted, run it again; it finishes the migration. Details:
[docs/migration.md](docs/migration.md).

## Uninstall

```sh
sudo ./uninstall.sh   # or --dry-run
sudo reboot           # BAR1 is back to stock after the reboot
```

Until the reboot BAR1 stays enlarged; the live rollback is in [docs/manual-procedure.md](docs/manual-procedure.md).
Uninstall removes the udev rule first and stops a record unit that is still waiting, so nothing writes the record or
the option file again. Your own driver keys in the option file (such as `RMDynBar1P2PEnable=0`) stay, and uninstall
prints where ([docs/driver-option.md](docs/driver-option.md#uninstall)). Problems:
[docs/troubleshooting.md](docs/troubleshooting.md).

## Reporting compatibility

Run `sudo geforce-bar1-resize check --report` (read-only; before installing,
`sudo scripts/geforce-bar1-resize check --report --vram <SIZE>`) and open an issue with the *Compatibility report*
template, including its output. Owners of a memory-modded RTX 4090 / 4090D 48GB: see
[docs/hardware.md](docs/hardware.md#help-wanted-rtx-4090--4090d-48gb-64-gib-bar1).

## GPU-to-GPU P2P

With BAR1 enlarged and `RMForceStaticBar1=0` in place, cards can copy directly to each other with the patched NVIDIA
open kernel modules in [geforce-dynbar1-p2p](https://github.com/noon-at-cgn/geforce-dynbar1-p2p) (verified on RTX
3080 20GB pairs).

## Credits

The technique for laying out the windows behind a PCIe switch was first shown by `tools/server-161-bar1-layout` in
[gu64](https://github.com/84634E1A607A/gpu-unlock-4090-48g-64g-bar1), for one fixed server. `gbr_layout` is an
independent, generic implementation.

## Licence

MIT, see `LICENSE`. The kernel module in `kernel/gbr_layout` is dual-licensed `GPL-2.0-only OR MIT`. Every file
carries its SPDX identifier; licence texts are in `LICENSES/`.

Not affiliated with or endorsed by NVIDIA. NVIDIA and GeForce are trademarks of NVIDIA Corporation.
