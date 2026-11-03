<!-- SPDX-License-Identifier: MIT -->
# The console card

The card that drives the console (`boot_vga` = 1, or a firmware framebuffer inside its BARs) is included by default.

- **VGA-class card (`0300`):** writing `resource1_resize` makes the kernel remove the firmware framebuffer
  (simpledrm, simplefb, efifb, vesafb) and vgacon on that card before it turns memory decode off and resizes, even if
  the resize then fails (`drivers/pci/pci-sysfs.c`, `aperture_remove_conflicting_pci_devices()`; checked in 6.6, 6.14,
  6.18 and 7.x). The console is blank from the resize until `nvidia-drm` (with `fbdev=1`) or a display server takes
  over. The journal says `console card: the kernel removes the firmware framebuffer (...) before the resize`.
- **3D-controller function (`0302`) with a firmware framebuffer inside one of its BARs:** always skipped, without an
  override: nothing would remove the framebuffer, which would keep writing to the old address after the move.
- **Behind a PCIe switch:** the layout module refuses the root port of the boot VGA device (and of any BAR with a
  foreign child resource), so the other cards below that root port stay stock too. Put the console card on a CPU root
  port, or set `console=skip` for it.
- **Leaving it stock:** `CONSOLE=skip`, or `console=skip` in its `CARD[]` entry.
- **Families other than Ampere and Ada:** once the firmware framebuffer is gone, the driver may make VBE int10h calls
  when it unloads; on Blackwell with CSM that was reported as a 2-4 minute hang or a GSP crash. The journal adds a
  note when `nvidia-drm` modeset/fbdev is not configured; `console=skip` avoids it.

Verified on the RTX 3080 20GB console card at warm and cold boots: BAR1 resized, the console on `nvidia-drmdrmfb`
afterwards, no Xid or AER. The firmware framebuffer handover is also covered by emulated console cards
([testing.md](testing.md)). Real GOP framebuffers on other families and the int10h behaviour are untested.

A runtime unbind of the console card hangs unless the console is detached first: see
[manual-procedure.md](manual-procedure.md).
