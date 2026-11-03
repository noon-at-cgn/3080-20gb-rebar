<!-- SPDX-License-Identifier: MIT -->
# Upgrading from 3080-20gb-rebar

`geforce-bar1-resize` is the renamed and generalized 3080-20gb-rebar. Running `sudo ./install.sh` on a host with the
old install migrates it; `--dry-run` shows every step first. Running it again changes nothing.

| Old | New |
|---|---|
| `/usr/local/sbin/rebar-arm.sh`, `scripts/rebar-check.sh` | `/usr/local/sbin/geforce-bar1-resize` (`boot`, `check`, ...) |
| `rebar-arm.service` | `geforce-bar1-resize.service` |
| `/etc/rebar-arm.conf` | `/etc/geforce-bar1-resize.conf` |
| `/etc/modprobe.d/zz-nvidia-static-bar1.conf` | `/etc/modprobe.d/zz-geforce-bar1-resize.conf` |
| `/var/backups/rebar-arm/` | `/var/backups/geforce-bar1-resize/` (the old directory is left in place) |

What `install.sh` does, in order:

1. Maps the old config into the new one, if there is no new one yet: `REBAR_BDFS` becomes the explicit `CARDS` list
   (so the same cards as before; it prints which cards `CARDS=auto` would add, such as a console card the old
   installer left out), `REBAR_N` becomes `SIZE`, `REBAR_ARM=none` becomes `ROUTE=resize`, `REBAR_LAYOUT` becomes
   `LAYOUT`. `REBAR_IDS` is dropped: the structural checks decide, and the card list stays explicit. Without an old
   driver option file the new config gets `DRIVER_OPTION=off`, as before.
2. Keeps every key of the old option file other than `RMForceStaticBar1=0` (for example the P2P opt-out
   `RMDynBar1P2PEnable=0`) as `keys=` in a `CARD[<address>]` entry with the card's `ids=`.
   Before anything is written, every migrated value must fit the new schema (PCI addresses, `REBAR_N` 0..13,
   `REBAR_LAYOUT` `off`, `auto`, `dryrun` or `force`, `K=V;` keys with a decimal or `0x` value): the config is sourced
   at every boot, so anything else (quotes, `$(…)`, backticks) stops the install with the line to fix, and nothing is
   changed.
3. Installs the new script, units, udev rule and config, and writes the new option file, while the old install is
   still in place.
4. Writes `/etc/geforce-bar1-resize/migrating` (with whether `rebar-arm.service` was enabled), disables
   `rebar-arm.service` and copies its drop-ins (`rebar-arm.service.d/*.conf`) to `geforce-bar1-resize.service.d/`
   with a header comment.
5. Moves the old script, unit, drop-in directory, config, enable link and option file to
   `/var/backups/geforce-bar1-resize/<stamp>/migrated-from-rebar-arm/`, with a `RESTORE.txt`, and removes the old
   `rebar_layout` module (its DKMS registration, sources and `.ko` files, moved to the same directory).
6. Enables `geforce-bar1-resize.service` if `rebar-arm.service` was enabled, only after the old files are gone, so
   no boot ever runs both.
7. Writes `/etc/geforce-bar1-resize/migrated` and removes `migrating`.

If the migration is interrupted (Ctrl-C, crash, power loss), run `install.sh` again. Before step 4 the old install
is still complete and the rerun migrates it, keeping the config step 3 wrote. From step 4 on, `migrating` tells the
rerun to finish the migration and to enable `geforce-bar1-resize.service` if the old unit was enabled; the config
is already mapped. Only that file turns this on: deleting `/etc/geforce-bar1-resize` later does not make an install
enable the unit.

Until `install.sh` has run, the new script reads `/etc/rebar-arm.conf` itself (keys logged as deprecated), and the
boot run warns while old files are present. `uninstall.sh` removes the old names too.

**Going back:** `sudo ./uninstall.sh`, then follow `RESTORE.txt` in the backup directory. If uninstall left
`/etc/modprobe.d/zz-geforce-bar1-resize.conf` with your driver keys, move any you still want into the restored
`zz-nvidia-static-bar1.conf` and delete it: only one of the two lines takes effect.
