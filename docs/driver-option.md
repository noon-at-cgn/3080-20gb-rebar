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
  (applied last). A repeated key keeps its last value, so your own `RMForceStaticBar1=1` for a card wins. In the
  files `RMForceStaticBar1=0` counts as the tool's own key; in `keys=` it is yours, so
  `keys=RMForceStaticBar1=1;RMForceStaticBar1=0;` writes `=0`. A card that gets the tool's `RMForceStaticBar1=0` and
  whose `keys=` ends at `=0` has it once; its `# keys from config:` entry then leaves `RMForceStaticBar1` out.
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

## Static BAR1 on a card whose BAR1 equals VRAM

Some cards list no BAR1 size above their VRAM, such as the 16 GB RTX 50 cards (reported on an RTX 5060 Ti 16 GB,
GB206). geforce-bar1-resize has nothing to enlarge there and never writes the card ([hardware.md](hardware.md)).
NVIDIA's own BAR1 P2P on such a card needs static BAR1, which the driver does not turn on by itself when BAR1 equals
VRAM, so it is forced with `RMForceStaticBar1=1`. With the 610 and 620 drivers the GPU can then fail to initialize:

```
NVRM: GPU0 dmaAllocMapping_GM107: Requested BAR1 VA Lo=0x20000000 Hi=0x4023fffff
NVRM: GPU0 kbusEnableStaticBar1Mapping_TU102: Failed to create the static bar1 mapping offset0x20000000 size 0x3e2400000
NVRM: GPU0 RmInitAdapter: RmInitNvDevice failed, bailing out of RmInitAdapter
```

The driver places the static mapping at the first 512 MiB boundary after its console and mailbox areas (512 MiB here)
and sizes it to VRAM minus the memory it reserves for itself; with `RMForceStaticBar1=1` it checks only that size
against BAR1, not the offset (read from the open kernel modules 580.105.08, 610.43.02, 615.71.09 and 620.70.06; all
of them do this). Once VRAM minus the reserved memory exceeds BAR1 minus 512 MiB, the mapping runs past the end of
BAR1. What changed in 610 is the reserved memory: newer drivers reserve less. tronx2100 measured 467 MiB reserved
with 580.178.04 (fits, 26 MiB left), 426 MiB with 610.57.04 (16 MiB too large) and 405 MiB with 620.70.06 (36 MiB
too large).

The documented key `RMIncreaseRsvdMemorySizeMB` makes the driver reserve more and so shrinks the mapping. In the same
report the reserved size grew by about twice the value: with `RMIncreaseRsvdMemorySizeMB=24` on 620.70.06 it went
from 405 to 453 MiB, both GPUs initialized and P2P copies in both directions were correct again, at a cost of about
48 MiB of VRAM per card. The reporter's formula, with the values `nvidia-smi` reports in MiB (VRAM total, VRAM
reserved, BAR1 total):

```
deficit = (total - reserved + 2) - (BAR1 - 512)
RMIncreaseRsvdMemorySizeMB = ceil((deficit + 8) / 2)
```

Recompute it after every driver change. To have the option file carry the keys, add them to the card's `keys=` in
`/etc/geforce-bar1-resize.conf` (applied last), next to any P2P keys you use, then run
`sudo geforce-bar1-resize driver-option --write` and reboot:

```bash
declare -A CARD=(
  [0000:01:00.0]="keys=RMForceStaticBar1=1;RMIncreaseRsvdMemorySizeMB=24;"
)
```

geforce-bar1-resize warns about such a card in the boot log, in `check` and in `driver-option` when the last
`RMForceStaticBar1` in its group (the option files, then `keys=`) is `1` and it has no `RMIncreaseRsvdMemorySizeMB`
(or `0`). Values are read as the driver reads them: `1`, `0x1` and `01` all mean `1`. Its BAR1 after the planned
resize and its VRAM decide which warning it gets:

- **BAR1 at least VRAM but less than VRAM + 512 MiB**, driver 610 or later: add `RMIncreaseRsvdMemorySizeMB`. The
  version comes from the nvidia module the next load uses (`modinfo`), else from the loaded one, else from the VRAM
  record; when none is known the warning says `driver 610 or later`.
- **BAR1 less than VRAM**, on any driver version: remove the key. Forced static BAR1 needs BAR1 >= VRAM unless
  `RMIncreaseRsvdMemorySizeMB` reserves the difference. Without it, when the mapping is larger than the whole BAR1 the
  driver refuses the key (`NV_ERR_INVALID_REGISTRY_KEY`; the kernel log says `is not large enough to map FB size`),
  and when it fits it still runs past the end of BAR1. Either way the card does not initialize.

Without a known VRAM (record or `check --vram`) there is no warning. It is a hint only and changes no write, route,
file or exit status. The boot log (timestamps left out) and `driver-option` show it as below; `record` logs the
`driver-option` lines with a `driver-option: ` prefix, and `check` prints the first line as `warning` and the second
as `note`, without the address and `warning:`. A 16 GB card at a 16 GiB BAR1:

```
0000:01:00.0 warning: RMForceStaticBar1=1 with BAR1 16384 MiB, VRAM 16311 MiB: driver 620.70.06 may fail to initialize the card
0000:01:00.0 the static mapping starts at 512 MiB; add RMIncreaseRsvdMemorySizeMB to its keys= (docs/driver-option.md)
```

A 20 GB card left at a 256 MiB BAR1 (for example one the tool skips):

```
0000:01:00.0 warning: RMForceStaticBar1=1 with BAR1 256 MiB, VRAM 20480 MiB: no driver version can initialize the card
0000:01:00.0 forced static BAR1 needs BAR1 >= VRAM; remove RMForceStaticBar1 for this card (docs/driver-option.md)
```

Reported by tronx2100 in [#4](https://github.com/noon-at-cgn/geforce-bar1-resize/issues/4), with the full logs.

## Uninstall

`uninstall.sh` removes every `RMForceStaticBar1=0`, also one your `keys=` put there, but keeps every other key of the
file, per card. If `--adopt-driver-line` merged another file's line, it uncomments that line again
(`# adopted by geforce-bar1-resize:` removed, the file backed up first) and lists any key that was only in our file.
Otherwise it leaves `/etc/modprobe.d/zz-geforce-bar1-resize.conf` with only your keys, for example
`options nvidia NVreg_RegistryDwordsPerDevice="pci=0000:02:00.0;RMDynBar1P2PEnable=0;"`, and nothing at all when
there are none. Either way it prints what it kept and where. Delete that file if you no longer want the keys.
