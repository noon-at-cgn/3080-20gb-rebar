<!-- SPDX-License-Identifier: MIT -->
# Driver option: all of VRAM through BAR1

With a large BAR1 the NVIDIA driver switches to "static BAR1": it maps VRAM into BAR1 up front and counts
host-visible memory twice against it, so only about half of VRAM can be allocated for CPU access. Setting
`RMForceStaticBar1=0` for a card returns to on-demand mapping.

| Driver setting | Host-visible VRAM reachable per card (RTX 3080 20GB, 20480 MiB) |
|---|---|
| default | about 10.2 GiB |
| `RMForceStaticBar1=0` | about 20.0 GiB (about 98 %) |

Verified on driver 615.71.09 only; with another version the option is still written and the install and record logs
say so. Caveat: nvidia-smi *BAR1 Used* no longer tracks VRAM use.

## The file

`geforce-bar1-resize driver-option --write` (run by `install.sh`, and by `record` when it queries the cards)
writes `/etc/modprobe.d/zz-geforce-bar1-resize.conf` with one line; an unchanged file is left alone:

```
options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:01:00.0;RMForceStaticBar1=0;pci=0000:02:00.0;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
```

- One `pci=<address>;` group per card, `RMForceStaticBar1=0;` first, then your keys.
- **Which cards (`DRIVER_OPTION=auto`, the default):** every configured card whose route enlarges BAR1 through
  `0x610`, or that the last boot enlarged through `0x610` (`/run/geforce-bar1-resize/cards`). A card whose BAR1 is
  already at the target keeps `RMForceStaticBar1=0` when its `0x610` is armed or when this file (or, at migration, the
  old `zz-nvidia-static-bar1.conf`) already listed it with that key, unless another card is there now: the VRAM record
  holds that address with other ids, or `record` replaced the record of a card with other ids there and no write of
  this file has completed since (`/etc/geforce-bar1-resize/replaced`). A card swapped in with other ids does not
  inherit the old card's key ([troubleshooting.md](troubleshooting.md)). A card resized without `0x610` (resize only,
  best effort) keeps the driver's static BAR1: some P2P setups need it (stock RTX 50 BAR1 P2P, the static-BAR1 P2P
  patches), and forcing it off would break them silently. A card never listed and never enlarged through `0x610`
  never gets the key; a card whose planned `0x610` resize fails at boot keeps it, since the file follows the plan.
- **`on`** (`DRIVER_OPTION=on`, or `driver_option=on` for one card): also every resize-only and best-effort card, and
  a card whose BAR1 the firmware already made large enough. **`off`**: no card.
- **Your keys are kept:** every key you added to a group of the current file (for example a hand-added
  `RMDynBar1P2PEnable=0;`), the keys of the old `zz-nvidia-static-bar1.conf`, and `keys=` per card in the config
  (applied last). A repeated key keeps its last value, so your own `RMForceStaticBar1=1` for a card wins.
- **Removing a key:** the file's `# keys from config: pci=<address>;K=V; ...` comment records which keys came from
  `keys=`. A key removed from `keys=` is dropped at the next `sudo geforce-bar1-resize driver-option --write`
  (`record` runs it when it queries the cards, not for a card already recorded; run it yourself to apply it now, then
  reboot). A key you added to the file by hand stays until you delete it there.
- **Only one such line can take effect** (a second one anywhere in `modprobe.d` replaces it). Another file with an
  `NVreg_RegistryDwordsPerDevice` line stops `--write` (and `install.sh`) and prints the merged line.
  `--adopt-driver-line` merges that line and comments it out, after a backup. For a key set both there and in the
  card's `keys=`, `keys=` wins. A global `NVreg_RegistryDwords` with `RMForceStaticBar1` gets a warning. The boot run
  warns when it sees more than one per-device line.
- A rewrite keeps the old file in `/var/backups/geforce-bar1-resize/`; nothing left to list removes the file.
- The option applies at the next load of the nvidia module (reboot). If `nvidia.ko` is included in the initramfs (it
  must not be loaded from there, see the README's *Requirements*), run `update-initramfs -u` so its copy of the
  option file matches.

`--print` shows the file it would write; `--check` reports a foreign line (exit 3) and writes nothing.

## Turning it on or off

`DRIVER_OPTION=on` or `off` in the config (or `driver_option=on|off` for one card), then `sudo geforce-bar1-resize
driver-option --write` and a reboot. `sudo ./install.sh --driver-option on|off|auto` does both config and file.
`sudo geforce-bar1-resize check` shows the choice per card on its `driver` line.

## Uninstall

`uninstall.sh` removes `RMForceStaticBar1=0` but keeps every other key of the file, per card. If
`--adopt-driver-line` merged another file's line, it uncomments that line again (`# adopted by geforce-bar1-resize:`
removed, the file backed up first) and lists any key that was only in our file. Otherwise it leaves
`/etc/modprobe.d/zz-geforce-bar1-resize.conf` with only your keys, for example
`options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:02:00.0;RMDynBar1P2PEnable=0;"`, and nothing at all when
there are none. Either way it prints what it kept and where. Delete that file if you no longer want the keys.
