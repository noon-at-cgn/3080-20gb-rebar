<!-- SPDX-License-Identifier: MIT -->
# Testing

## What was verified

On real hardware: two RTX 3080 20GB cards (`10de:2206/10de:146d`) on driver 615.71.09 reach a 32 GiB BAR1 at every
warm and cold boot, console card included ([hardware.md](hardware.md)).

On emulated hardware (QEMU guests with emulated GeForce-like cards and PCIe switches, release and fault-injection
builds of the layout module):

- **Kernels:** Proxmox VE 6.14 and 7.0, Ubuntu 6.8, mainline 6.14 and master with KASAN and lockdep (layout module
  fault injection), and a full systemd boot on Debian 13 (6.12). The layout module builds without warnings on 10
  kernels from Debian 12's 6.1 to mainline master.
- **Topologies:** cards on CPU root ports; cards behind a switch, behind two levels of nested switches and behind
  switches on two host bridges; up to 12 cards below one root port; tight 64-bit address space (exact fit, 1 GiB
  short, one alignment step short).
- **Fault injection:** a failure forced at every step of the layout module is rolled back, and config space, the
  kernel's resources and `/proc/iomem` are restored byte for byte. A failed rollback keeps the driver hold and asks
  for a reboot. A SIGTERM while a card is being armed or while the layout module runs leaves every card consistent.
- **Routes:** resize only, `0x610`, already large, best effort; each structural check failing on its own; an override
  that does not latch, does not widen the capability or drops sizes is undone. A card without the GA102 layout
  (Blackwell-like: no VSEC at `0x600`, Resizable BAR elsewhere) is never written at `0x600`-`0x6ff`.
- **Console card:** the firmware framebuffer on a VGA card is removed by the kernel before the resize; a 3D-controller
  function with a framebuffer is skipped; the layout module refuses the console card's root port; `console=skip`.
- **Install:** migration from 3080-20gb-rebar, then boots with the service in its real place before udev, the VRAM
  record through the udev rule, a reinstall that changes nothing, DKMS and plain `make` module builds, uninstall.

## Real hardware

Two RTX 3080 20GB cards (`10de:2206/10de:146d`), each directly on a CPU root port, Linux 7.0 class kernel:

- **Install:** `install.sh` over an existing 3080-20gb-rebar install migrates it (old files to backups, the cards and
  size from the old config, the driver option for both cards, plan `0x610` to 32 GiB).
- **Boot:** both cards, the display card included, come up with a 32 GiB BAR1 before udev, with the console handover
  logged. With one card set to `enable=no`, only the other is resized and the first is left untouched.
- **SR-IOV vGPU host:** with an SR-IOV preparation unit that removes and rescans the card, the service runs after that
  unit (`After=`) and before the driver loads. With both cards at 32 GiB the NVIDIA vGPU-KVM host driver 580.159.01
  enables 4 VFs per card; the vGPU types are unaffected and *BAR1 Used* is 1 MiB. VF enable and passthrough tools right
  after the driver loads are not raced by the record unit. No Xid, AER or DMAR lines.
- **Layout module:** `gbr_layout` forced on a card below a CPU root port (no switch). The dry run predicted BAR1 at an
  address; an injected fault was rolled back byte for byte (4096 bytes of config space for the root port, the GPU and
  the audio function, the kernel's resources and `/proc/iomem`); the real run then placed BAR1 at exactly the
  predicted address. PCIe switches themselves are still untested on real hardware.
- **P2P** with the [geforce-dynbar1-p2p](https://github.com/noon-at-cgn/geforce-dynbar1-p2p) driver on both 32 GiB
  cards: the integrity test passes (264 cases, 1.4 TiB copied, about 10.3 GB/s each way).

Not covered on real hardware: a real PCIe switch and chips other than GA102.

## Results

| Hardware | Setup | Result |
|---|---|---|
| RTX 3080 20GB, 2 cards | driver 615.71.09, direct root ports, one console card | 32 GiB BAR1 on both, warm and cold boots, no Xid or AER |
| RTX 3080 20GB, 2 cards, NVIDIA vGPU-KVM host 580.159.01 with 4 VFs per card | direct root ports, SR-IOV preparation unit | 32 GiB BAR1 on both, VFs and vGPU types unaffected, BAR1 Used 1 MiB, no Xid, AER or DMAR |
| RTX 3080 20GB, `gbr_layout` forced on a CPU root port | dry run, injected fault, real run | prediction met, rollback byte for byte, BAR1 at the predicted address |
| RTX 3080 20GB, 2 cards, P2P | driver 615.71.09 with geforce-dynbar1-p2p | integrity test PASS: 264 cases, 1.4 TiB, about 10.3 GB/s each way |
| Emulated, every topology above | Proxmox VE 6.14 and 7.0, Ubuntu 6.8 | 56 boots per kernel (168), all pass |
| Emulated, switch topologies with fault injection | mainline 6.14 and master, KASAN and lockdep | 5 boots per kernel (10), all pass, no KASAN or lockdep report |
| Emulated, full boot with systemd | Debian 13, 6.12 | migration from 3080-20gb-rebar, 3 service boots, VRAM record, reinstall, uninstall: 14 of 14 checks pass |
| Layout module build (release and fault-injection) | Debian 6.1 (gcc 12), Ubuntu 6.8 (gcc 13), Debian 6.12, Proxmox VE 6.14, 6.17 and 7.0, mainline 6.6, 6.14, 6.18 and master | 10 kernels, no compiler warnings |

## Stand-in tests

`tests/run.sh` runs `scripts/geforce-bar1-resize`, `install.sh` and `uninstall.sh` against a fake
`/sys/bus/pci/devices` tree, a fake `setpci` that keeps config registers in files, and a small `LD_PRELOAD` shim for
the sysfs behaviour a plain file cannot imitate (resize errors, `drivers_probe`, pending resizes). The scripts run as
copies in which only `/sys/` and `/proc/iomem` point into the fake tree; no GPU, kernel module or real sysfs file is
touched. The 100 cases cover discovery, the structural checks, labels, sizing, every route including best effort, the
dry run, the VRAM record, config precedence and the old `REBAR_*` keys, the driver option per route, the static BAR1
warnings, the console rules, the layout batches and driver hold (with a stand-in `modprobe`), `repair`, `check`,
install, uninstall (including the driver keys it keeps), the refusal to run without root, the migration from
3080-20gb-rebar (also interrupted at every step), and the P2P companion's view of the driver option file.

Run it as a normal user (it refuses root) from the repository root:

```sh
tests/run.sh          # every case; tests/run.sh 0 1 runs only cases whose id starts with 0 or 1
```

It needs bash, coreutils, grep, sed, awk, find, `cmp`, `ps`, `setsid`, `timeout` and a C compiler (`cc`, for the
shim); `git` and network only for the 6 P2P cases, which are skipped with a note otherwise (`P2P_TREE=<checkout>`
uses an existing checkout instead of cloning). It prints a PASS, FAIL or SKIP line per case and a summary, and exits 0
when no case failed (otherwise the number of failures, at most 125). Scratch files go to a new directory under
`${TMPDIR:-/tmp}`, deleted when everything passes and kept, with a log per case, when something fails; a `$WORK` you
set is used instead and never deleted. GitHub Actions runs `shellcheck` and `tests/run.sh` on `ubuntu-latest`
(`.github/workflows/tests.yml`).
