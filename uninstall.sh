#!/bin/bash
# Remove the BAR1 size override boot service installed by install.sh, and the --lift-ceiling driver option file.
# Nothing is written to any GPU and no driver module is reloaded. Removed files are moved into a new timestamped
# backup; earlier install backups are kept.
#
# Usage: sudo ./uninstall.sh [--dry-run] [--root DIR]
#   --dry-run    print what would be done, change nothing
#   --root DIR   uninstall from staging root DIR; no systemctl calls
set -u

UNIT=rebar-arm.service
LIFTFILE=/etc/modprobe.d/zz-nvidia-static-bar1.conf
FILES=("/etc/systemd/system/$UNIT" "/etc/systemd/system/$UNIT.d" /usr/local/sbin/rebar-arm.sh /etc/rebar-arm.conf "$LIFTFILE")
DRY=0 ROOT=""
die() { echo "uninstall: $*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/{/^#/p}' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
	case $1 in
		--dry-run) DRY=1; shift ;;
		--root) [ $# -ge 2 ] || usage 2; ROOT=${2%/}; shift 2 ;;
		-h | --help) usage 0 ;;
		*) echo "uninstall: unknown option $1" >&2; usage 2 ;;
	esac
done
[ -z "$ROOT" ] || [ -d "$ROOT" ] || die "--root $ROOT is not a directory"
if [ "$(id -u)" != 0 ]; then
	[ -n "$ROOT" ] || [ "$DRY" = 1 ] || die "needs root (or use --dry-run / --root DIR)"
fi
run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }
did=""; [ "$DRY" = 1 ] && did="would be "

if [ -n "$ROOT" ]; then
	echo "skipped: systemctl disable $UNIT (--root)"
	wants=$ROOT/etc/systemd/system/sysinit.target.wants/$UNIT
	if [ -L "$wants" ]; then run rm "$wants"; echo "${did}removed enable link $wants"; fi
else
	run systemctl disable "$UNIT" || echo "systemctl disable failed (unit not installed or not enabled?)"
fi

BACKUP=$ROOT/var/backups/rebar-arm/uninstall-$(date +%Y%m%d-%H%M%S)
for f in "${FILES[@]}"; do
	if [ -e "$ROOT$f" ]; then
		run mkdir -p "$BACKUP$(dirname "$f")"
		run mv "$ROOT$f" "$BACKUP$f"
		echo "${did}removed $ROOT$f (kept as $BACKUP$f)"
	else
		echo "absent $ROOT$f"
	fi
done

if [ -n "$ROOT" ]; then
	echo "skipped: systemctl daemon-reload (--root)"
else
	run systemctl daemon-reload
fi

echo
echo "Backups are kept under $ROOT/var/backups/rebar-arm/:"
find "$ROOT/var/backups/rebar-arm" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | sed 's/^/  /'
echo "Log kept: /var/log/rebar-arm.log"
echo
echo "BAR1 IS STILL LARGE. Uninstalling changes no GPU: every armed card keeps its large BAR1 and armed"
echo "0x610 until the next reboot, or until you do the manual live rollback (README, Rollback: shrink"
echo "with resource1_resize first, then write 0x610 back to 00001001)."
if [ -e "$BACKUP$LIFTFILE" ] || { [ "$DRY" = 1 ] && [ -e "$ROOT$LIFTFILE" ]; }; then
	echo "The driver option RMForceStaticBar1=0 stays active in the loaded nvidia module until the next reboot or"
	echo "driver reload (README, Reaching all of VRAM through the aperture)."
fi
