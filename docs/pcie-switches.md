<!-- SPDX-License-Identifier: MIT -->
# Cards behind PCIe switches (experimental)

**Experimental and off by default.** The layout module is tested in QEMU on emulated switch topologies and on real
silicon forced on a CPU root port (no switch), but not yet on real switch hardware, so `LAYOUT` is `off` in the
shipped config and in the installer: nothing here runs unless you turn it on with `install.sh --layout auto` (or
`LAYOUT=auto` in `/etc/geforce-bar1-resize.conf`, with the module built).

Behind a PCIe switch the plain resize fails with `No space left on device` (`No such file or directory` on 6.14-era
kernels): the firmware sized the switch windows for 256 MiB BARs, and Linux only grows the window directly above the
card. With `LAYOUT=auto` the service then loads the `gbr_layout` kernel module (`kernel/gbr_layout`), which lays out
every 64-bit prefetchable window and BAR below the card's root port again. It runs while no driver is bound: the
service holds every function below the root ports with `driver_override` until it is done. The module plans the
whole layout and checks that it fits the host bridge before it writes anything, then moves the windows and BARs,
checks each one against config space, and on any failure restores every saved register and resource. It works one
root port at a time; after a failure the remaining root ports are skipped, and those already done keep their new
layout. The module takes one size index and at most 4 root ports per load, so the service runs it in batches (one
per size, at most 4 root ports each) under one driver hold, and resolves every card before it releases the hold.
Like the resize, all of it is volatile: a reboot returns the firmware's layout, and the service runs again.

## Requirements

- The layout module: `install.sh --layout auto` builds it for the running kernel when a selected card sits behind a
  switch (`--layout-module` builds it in any case; it needs the kernel headers, and with DKMS it is rebuilt for every
  new kernel).
- Each root port needs one 64-bit window for all of its cards, aligned to the card's BAR1 size. With one card per
  switch port that is (2 × cards − 1) × BAR1 size plus 32 MiB, because each card's 32 MiB second BAR pushes the next
  card to the next aligned slot: 96 GiB for two 32 GiB cards, 288 GiB for five. The firmware's 64-bit MMIO range must
  have that much free space (Supermicro: *MMIOH Base* and *MMIO High Size*); `geforce-bar1-resize check --layout-plan`
  prints the exact size.

## Trying it safely

Try it in steps; the first ones only plan:

```sh
sudo ./install.sh --layout dryrun --enable              # module installed, LAYOUT=dryrun
sudo geforce-bar1-resize check --layout-plan            # read-only: loads the module with dry_run=1
sudo reboot                                             # the boot run plans and logs; cards stay stock
journalctl -b -u geforce-bar1-resize                    # "result dry-run", "predicted 0x..." per port
sudo ./install.sh --layout auto                         # LAYOUT=auto
sudo reboot
```

The plan fits when each root port's `window ... align ...` line ends in `predicted 0x...` and no line says
`would-refuse`. On a running system `--layout-plan` also prints `would-refuse` for the bound NVIDIA driver and the
not yet widened capability (`capability not widened?`); the boot run has neither.

A dry run (the boot run with `LAYOUT=dryrun`, or `--layout-plan`) can wake runtime-suspended functions below the root
port that have no driver, such as a card's audio function. The PCI core may then restore the function's saved config,
for example memory decoding off on an unbound audio function. This is harmless: binding a driver enables it again.

## Recovery: driver hold and "reboot required"

While the layout module runs, the service sets `driver_override` to `geforce-bar1-hold` on every unbound function
below the cards' root ports, so no driver binds to a device that is being moved; the journal says
`driver hold released on ...` when it is done. A held function gets no driver, so the NVIDIA driver does not see the
card. `grep -l geforce-bar1-hold /sys/bus/pci/devices/*/driver_override` lists the held functions, and
`journalctl -b -u geforce-bar1-resize` says why:

| Journal | Meaning | Do |
|---|---|---|
| `gbr_layout rollback failed: driver hold kept on ...; reboot required` | The module could not restore every register; memory decode stays off below that root port. | Reboot. Do not release the hold. |
| `gbr_layout outcome unknown (modprobe exit ..., no result in the kernel log)`, then `driver hold kept on ...; reboot required` | The module failed and its result is not in the kernel log. | Reboot, or check the cards and release the hold by hand. |
| `<BDF> BAR registers disagree with the kernel: driver_override geforce-bar1-hold set, reboot required` | A failed resize left a BAR register that does not match the kernel's address for it. | Reboot. |
| `driver hold (driver_override geforce-bar1-hold) on ...` and no later `driver hold released on ...` | The service was killed mid-run. | Reboot. |

With several batches (several size indexes, or more than 4 root ports), a failed batch stops the later ones, and
only the functions below that batch's root ports stay held; the line `driver hold kept on ...` names them. Every card
below those root ports, including one an earlier batch enlarged, is logged `state unknown ...; reboot required`.
The other root ports are released as usual.

*Reboot required* means the cards' state is unknown or unsafe until the firmware sets them up again. Everything the
service and the module change is volatile, so any reboot restores the firmware's layout and stock cards, and the
service runs again. If the next boot fails the same way, set `LAYOUT=off` in `/etc/geforce-bar1-resize.conf` and open
an issue with the journal.

To release the hold by hand, as the journal describes, first check each card: `lspci -vv -s <BDF>` shows `Mem+` on
the `Control:` line and a `Region 1` of the stock or the target size. Then, as root:

```sh
echo > /sys/bus/pci/devices/<fn>/driver_override   # for each held function
echo <fn> > /sys/bus/pci/drivers_probe
```

## Troubleshooting

| Problem | Fix |
|---|---|
| Journal: `gbr_layout: root <port> refuse <fn> bound to <driver>` (the service also logs `<fn> is bound to <driver>; the layout refuses its root port`) | A driver owned a function below the card's root port before the service ran, usually because it loads from the initramfs. Keep that driver out of the initramfs or blacklist it; until then the cards run stock. |
| Journal: `gbr_layout: root <port> refuse: window 0x... align 0x... fits no host bridge window` | The firmware's 64-bit MMIO range has no free, aligned space that large. Enlarge it in the BIOS (*Requirements*), enlarge fewer cards on that root port, or lower `SIZE`. The cards are disarmed and run stock. |
| Journal: `<BDF> is the console card: the layout module refuses its root port` | The module never moves the boot VGA device. Put the console card on a CPU root port, or set `console=skip` for it ([console.md](console.md)). |
| The dry run predicted an address, but the real run logs `gbr_layout: root <port> result rolled-back` | A step of the move failed (the journal shows which), or the address space changed between the plan and the move. The plan already skips host window ranges that the kernel reserves (`candidate ... touches an e820 range; skipped`). Everything was restored and the cards run stock; open an issue with the journal and `/proc/iomem`. |
| After lowering `SIZE`, a laid-out switch keeps its large windows | Expected: the module never shrinks or repacks a running system. Reboot; the firmware's layout comes back and the new size is laid out from it. |

## Status

The module is new. It is tested in QEMU on emulated switch topologies (nested switches, several root ports and host
bridges, tight address space, every failure point) with Proxmox VE, Debian and Ubuntu kernels and mainline:
[testing.md](testing.md). On real silicon it ran forced on a card below a CPU root port: the dry run's prediction was
met, an injected fault was rolled back byte for byte and the real run placed BAR1 at the predicted address. It has not
run on real switch hardware yet; the first report from a system with PCIe
switches, for the previous version without the module, is
[issue #3](https://github.com/noon-at-cgn/geforce-bar1-resize/issues/3). Reports from real hardware are welcome, with
the *Compatibility report* issue template.

## Prior art and licence

Prior art for the technique: `tools/server-161-bar1-layout` in
[gu64](https://github.com/84634E1A607A/gpu-unlock-4090-48g-64g-bar1), which releases, resizes and reprograms the
windows for one fixed server. `gbr_layout` is a separate, generic implementation.

MIT, see `LICENSE`. The kernel module in `kernel/gbr_layout` is dual-licensed `GPL-2.0-only OR MIT`.
