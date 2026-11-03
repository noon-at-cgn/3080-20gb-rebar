<!-- SPDX-License-Identifier: MIT -->
# Configuration

`/etc/geforce-bar1-resize.conf` is a bash file, sourced as root by `geforce-bar1-resize` (another path: `GBR_CONF`).
The boot unit runs only when it exists. `install.sh` writes it; its options set the keys below and leave the rest
of an existing file alone. Every key is optional. An invalid value is logged and the default used; it never stops
the run. Example: `config/geforce-bar1-resize.conf.example`.

| Key | Default | Values |
|---|---|---|
| `CARDS` | `auto` | `auto`: every qualifying NVIDIA display function; or full PCI addresses, space-separated |
| `EXCLUDE` | empty | selectors never touched: `0000:01:00.0`, `10de:2684`, `10de:2684/1458:4105` |
| `SIZE` | `auto` | `auto` (smallest `64 MiB << n` at least VRAM), `0`..`13` (`n`), or `64M`..`512G` (rounded up to a power of two) |
| `ROUTE` | `auto` | `auto`, `resize` (never write `0x610`), `0x610` (still needs the structural checks), `0x610!`, `skip`. `0x610!` forces the `0x610` route when the only failed structural check is the ReBAR layout check S5, for cards whose ReBAR capability sits elsewhere ([how-it-works.md](how-it-works.md)); this is untested territory: use it only with `check --report` output in hand (config only; `install.sh --route` does not take it). When no route reaches the target and the card lists a size above its BAR1, every route but `skip` resizes to the largest listed size (best effort, logged as below VRAM; [how-it-works.md](how-it-works.md)) |
| `LAYOUT` | `off` | cards behind a PCIe switch: `off`, `auto`, `dryrun`, `force` ([pcie-switches.md](pcie-switches.md)) |
| `DRIVER_OPTION` | `auto` | `RMForceStaticBar1=0`: `auto` only for cards enlarged through `0x610`, `on` for every card with a large BAR1 (also resize only and best effort), `off` for none ([driver-option.md](driver-option.md)) |
| `CONSOLE` | `include` | `include` or `skip` for the card that drives the console ([console.md](console.md)) |
| `LOG` | `/var/log/geforce-bar1-resize.log` | log file; the journal is the authoritative log |
| `RECORD_DELAY` | `60` | seconds `0`..`3600` the record unit waits after the NVIDIA driver binds a card that has no VRAM record (or one with other ids) before `nvidia-smi` opens it, so tools that unbind right after the driver loads (`sriov-manage`, a VFIO rebind) get the driver's unbind lock first; the card is then queried only if it is still bound to `nvidia`. For a card already recorded with the same ids the record unit runs no `nvidia-smi`; other runs may still open that card: the query the record unit makes for another card, or `record` without an address (as `install.sh` runs it), queries every GPU ([how-it-works.md](how-it-works.md)) |

## Per-card entries

```bash
declare -A CARD=(
  [0000:01:00.0]="size=16G"
  [0000:02:00.0]="enable=no"
  [10de:2684]="size=64G"
  [10de:2684/1458:4105]="route=skip"
)
```

The first matching entry wins: the card's address (with `ids=` in the entry, those must match the card now at that
address, otherwise the entry is logged and ignored, which covers cards that moved), then
`vendor:device/subvendor:subdevice`, then `vendor:device`. Keys: `enable=yes|no` (`no`: the card is planned as
skipped and never written, `repair` included), `size=`, `route=` (also `0x610!`, as for `ROUTE`: forces the `0x610`
route when S5, the ReBAR layout check, is the only failed structural check; untested territory, use it only with
`check --report` output in hand), `layout=`, `driver_option=auto|on|off`, `console=include|skip`, `keys=` (more
driver registry keys for this card, each `K=V;`, for example `keys=RMDynBar1P2PEnable=0;`;
[driver-option.md](driver-option.md)), `ids=` (address entries only, e.g. `ids=10de:2684/1458:4105`). Unset keys
come from the global settings.

## Old keys (3080-20gb-rebar)

If only `/etc/rebar-arm.conf` exists (`install.sh` has not migrated it), it is read and its keys are mapped, each
logged as `deprecated key`:

| Old | New |
|---|---|
| `REBAR_BDFS` | `CARDS` (the explicit list) |
| `REBAR_N` | `SIZE=<n>` (9 when unset, the old default) |
| `REBAR_ARM` | `ROUTE`: `0x610` becomes `auto`, `none` becomes `resize`, anything else `skip` |
| `REBAR_LAYOUT` | `LAYOUT` |
| `REBAR_IDS` | kept as an extra filter: only these ids are touched |
| `REBAR_LOG` | `LOG` |

`install.sh` options from 3080-20gb-rebar (`--bdfs`, `--n`, `--resize-only`, `--layout` without a value,
`--layout-dryrun`, `--lift-ceiling`, `--no-lift-ceiling`, `--include-console`, `--force`) are accepted for one
release and print their replacement.

## Files

| File | Written by |
|---|---|
| `/usr/local/sbin/geforce-bar1-resize` | `install.sh` |
| `/etc/systemd/system/geforce-bar1-resize.service`, `geforce-bar1-resize-record@.service` | `install.sh` |
| `/etc/udev/rules.d/90-geforce-bar1-resize.rules` | `install.sh` |
| `/etc/geforce-bar1-resize/vram` | `geforce-bar1-resize record`, with its lock file `.lock` (never edit; after a VRAM change that keeps the ids, run `sudo geforce-bar1-resize record`, [troubleshooting.md](troubleshooting.md)) |
| `/etc/geforce-bar1-resize/replaced` | `geforce-bar1-resize record` after a card swap (the address and the old card's ids); removed by the next `driver-option --write` that completes (`install.sh` runs one; `record` too, unless `DRIVER_OPTION=off` with no `CARD[]` entries and no option file) |
| `/etc/modprobe.d/zz-geforce-bar1-resize.conf` | `geforce-bar1-resize driver-option --write` |
| `/run/geforce-bar1-resize/cards` | the boot run: the route and result (`enlarged`, `stock` or `unknown`) of each card it planned this boot, except one whose BAR1 was already large without `0x610` |
| `/etc/geforce-bar1-resize/migrated`, `migrating` | `install.sh` when it migrates 3080-20gb-rebar ([migration.md](migration.md)) |
| `/var/log/geforce-bar1-resize.log` | the boot run, `record` and `repair` (`LOG`; the journal is authoritative) |
| `/usr/src/geforce-bar1-layout-<version>/` (DKMS), or `/lib/modules/<kernel>/updates/gbr_layout.ko` | `install.sh --layout-module`, or a `LAYOUT` other than `off` with a card behind a switch |
| `/var/backups/geforce-bar1-resize/` | backups of every file `install.sh`, `uninstall.sh` or `driver-option` replaced or removed |
