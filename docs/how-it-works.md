<!-- SPDX-License-Identifier: MIT -->
# How it works

The CPU reaches a GPU's memory through a PCI memory window called BAR1. Most GeForce cards get a 256 MiB window, so
only a small slice of VRAM is visible at any moment and larger host-visible allocations fail. A bigger window is
called Resizable BAR (ReBAR), and the card's firmware decides which sizes it offers. `geforce-bar1-resize` asks for
the larger window at boot, before the NVIDIA driver loads, and nothing is written to the card's flash.

## The boot run (`geforce-bar1-resize boot`)

The unit `geforce-bar1-resize.service` runs before systemd loads modules and before udev coldplug binds drivers, so
no driver owns the cards yet. For each card:

1. **Discovery:** a PCI function qualifies when it is NVIDIA (`10de`), a display controller (class `0300` VGA or
   `0302` 3D controller), its Resizable BAR capability has an entry for BAR1, the kernel exposes `resource1_resize`,
   and no driver is bound. The capability is found by walking the extended capability chain from `0x100`, not at a
   fixed offset. HDMI audio and every other function are never touched (with `LAYOUT`, every unbound function below
   the card's root port is held from drivers while the layout module runs, and its BARs may move;
   [pcie-switches.md](pcie-switches.md)). SR-IOV virtual functions are skipped (without a log line under
   `CARDS=auto`). Cards excluded in the config, and bound cards, are logged and left alone.
2. **Target size:** the smallest `64 MiB << n` that is at least the card's VRAM, `n` 0..13 (64 MiB..512 GiB): 20 GB
   gives 32 GiB, 48 GB gives 64 GiB, 12 GB gives 16 GiB. The VRAM size comes from `size=` in the config, or from
   `/etc/geforce-bar1-resize/vram`, which the record unit `geforce-bar1-resize-record@.service` writes when the NVIDIA
   driver binds a card (udev rule `90-geforce-bar1-resize.rules`, not for SR-IOV virtual functions). For a card already
   recorded with the same ids it runs no `nvidia-smi` (its query for another card, or `record` without an address, may
   still open it, since those query every GPU). Any other card is queried with `nvidia-smi` `RECORD_DELAY` seconds
   (default 60) after the bind, and only if it is still bound to `nvidia`, so tools that unbind or reconfigure a card
   right after the driver loads (`sriov-manage`, a VFIO rebind) get the driver's unbind lock first. A card the driver
   has never seen is skipped with `VRAM unknown`; it is enlarged from the next boot. The record is kept per address and
   ids, so it does not follow a VRAM change that keeps the ids (a memory mod, a swap for a card with the same ids):
   run `sudo geforce-bar1-resize record`, which without an address queries every card again, then reboot.
3. **Route:**
   - *none*: BAR1 is already at least the target (for example when the system firmware's Resizable BAR support or ReBAR
     firmware already enlarged it). BAR1 is never shrunk.
   - *resize only*: the capability already lists a size at least the target; BAR1 is resized to the smallest such
     size through `resource1_resize`, and `0x610` is never written.
   - *0x610*: the card passes the structural checks below; the frame-buffer size override in config space is
     armed (bits 11:7 of `0x610`, enable bit plus `VAL`), which makes the capability list sizes up to
     `64 MiB << VAL`, and then BAR1 is resized.
   - *best effort*: none of the above reaches the target, but the capability lists a size above the current BAR1
     (for example a 64 GB card that lists up to 32 GiB and has no `0x610` route, or `route=resize` on a card that
     lists less than its VRAM): resize only, to the largest listed size, `0x610` never written. The log says
     `<BDF> resize to <X> MiB, the largest size the card lists; below VRAM (<V> MiB)`, then `<BDF> because ...`.
     This is decided while planning: a `0x610` route that fails at boot still backs off to stock; it does not switch
     to best effort.
   - *skip*: anything else, with the reason in the log.
4. **Verification:** after arming, `0x610` must read back armed, the capability must list every size it listed
   before plus the target, and the kernel's resize mask must list the target; after the resize, BAR1's length must
   be the target. Any failure disarms the card again (`0x610` restored to the value it had before the run, or to stock
   when an earlier run had armed it). A failed resize that leaves a BAR register disagreeing with the kernel holds the
   card from drivers until a reboot (`driver_override geforce-bar1-hold`).

Cards are processed largest target first. A SIGTERM (stop, start timeout) stops arming further cards; every card
already touched is resolved before the script exits.

## Structural checks for the 0x610 route

`0x610` is written only when every check holds; there is no device-ID list. The values are those of GA102.

| # | Check |
|---|---|
| S1 | the capability chain walk reaches `0x600`, and its header is a vendor-specific capability (ID `000b`), version 1 |
| S2 | the VSEC header at `0x604` is ID `0001`, revision 1, length `0x024` |
| S3 | `0x60c` bit 11 (frame-buffer size override supported) is set and its reserved bits are 0 |
| S4 | `0x610`'s reserved bits are 0, and bits 11:7 are stock (0) or armed |
| S5 | the Resizable BAR capability is at `0xbb0` with BAR1's entry at `0xbbc`/`0xbc0` (the XVE layout) |
| S6 | the function is a type 0 endpoint |

A card that fails one is never written at `0x610`; it can still take the resize-only route. Hopper and Blackwell put
the Resizable BAR capability elsewhere (S5), so they are only ever resized when their capability already lists the
size. `ROUTE=0x610!` (or `route=0x610!` for one card) waives S5 when it is the only failed check: untested territory,
use it only with `check --report` output in hand. The checks are read-only; `geforce-bar1-resize check` prints each.

## Labels

A small table in the script names the configurations that have been verified (`docs/hardware.md`). It only labels log
lines `(verified)`, `(reported)` or `(untested)`; it never decides whether a card is touched.

## Driver option

With a large BAR the NVIDIA driver switches to "static BAR1", which limits CPU-accessible allocations (to about half of
VRAM on the RTX 3080 20GB). `RMForceStaticBar1=0` turns that off; by default (`DRIVER_OPTION=auto`) it is written only
for cards enlarged through `0x610`. Resize-only and best-effort cards keep static BAR1, which some P2P setups (stock RTX
50 BAR1 P2P, static-BAR1 P2P patches) need; `driver_option=on` adds it for them: [driver-option.md](driver-option.md).

## Cards behind PCIe switches

Behind a switch the plain resize fails (`ENOSPC`, or `ENOENT` on some kernels, for example 6.14). With `LAYOUT=auto`
such cards go to the `gbr_layout` kernel module, which lays out the windows below the root port again:
[pcie-switches.md](pcie-switches.md).

## Other subcommands

- `check [--vram SIZE] [--layout-plan] [--report] [BDF...]`: read-only report per card.
- `plan` (= `boot --dry-run`): logs what the next boot would do, writes nothing. Cards a driver holds now are planned
  as they will be at boot, before the driver binds.
- `record [--delay] [BDF]`: store VRAM sizes from `nvidia-smi` and update the driver option file. With `BDF`, no
  `nvidia-smi` runs for a card already recorded with the same ids; `--delay` waits `RECORD_DELAY` seconds first
  and skips a card no longer bound to `nvidia`. `geforce-bar1-resize-record@.service` runs `record --delay <BDF>`
  whenever the NVIDIA driver binds a card; `install.sh` runs `record` for every card.
- `repair [BDF...]`: after a device reset cleared `0x610` while BAR1 stayed enlarged, re-arm it on a bound card
  ([manual-procedure.md](manual-procedure.md#after-a-device-reset)).
- `driver-option [--print|--check|--write] [--adopt-driver-line]`: the driver option file.
