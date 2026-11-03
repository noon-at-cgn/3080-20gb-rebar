<!-- SPDX-License-Identifier: MIT -->
# Manual procedure (per card, as root)

What the boot service does, by hand, on a running system. The example is the verified RTX 3080 20GB (n = 9,
32 GiB, size index 15); for another card use its `n` (`geforce-bar1-resize check` prints the plan) and size index
`n + 6`. Run it only on a card that passes the structural checks.

1. Stop every GPU user; `fuser -v /dev/nvidia*` must print nothing.
2. If the card drives the display (`boot_vga` is `1`), detach the console or the unbind hangs:
   `echo 0 > /sys/class/vtconsole/vtcon1/bind` (the vtcon whose `name` is `(M) frame buffer device`).
3. `echo $BDF > /sys/bus/pci/drivers/nvidia/unbind`
4. `setpci -s $BDF 0x610.L=00000c80:00000f80` (bits 11:7 only: enable plus VAL 9), then check that `0x610` reads
   `00001c81` and `0xbbc` reads `000ffc00`.
5. `echo 15 > /sys/bus/pci/devices/$BDF/resource1_resize` (the size index, not bytes).
6. `echo $BDF > /sys/bus/pci/drivers/nvidia/bind`, then reattach the console if you detached it:
   `echo 1 > /sys/class/vtconsole/vtcon1/bind`.

A card whose capability already lists the size skips step 4.

## Rollback without a reboot

Do steps 1-3. Shrink BAR1 first with `echo 8 > /sys/bus/pci/devices/$BDF/resource1_resize`, and only then disarm
`0x610` with `setpci -s $BDF 0x610.L=00001001:00000f80`. Rebind the driver and reattach the console. Do not disarm
`0x610` while BAR1 is still enlarged.

## After a device reset

A reset (FLR, driver recovery) may clear `0x610` while BAR1 stays enlarged, so the capability no longer lists the
size BAR1 has. `sudo geforce-bar1-resize repair [BDF...]` re-arms `0x610` on a bound card when every structural check
passes and BAR1 is already exactly the target size; it leaves alone a card that is not bound, has `enable=no`,
`route=skip` or `route=resize`, or has an unknown size. Nothing runs it automatically. It is untested after a real
device reset.
