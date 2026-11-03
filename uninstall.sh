#!/bin/bash
# SPDX-License-Identifier: MIT
# Remove geforce-bar1-resize as install.sh put it in place: the script, the boot and record units, the udev rule, the
# config, the VRAM record, the driver option file and the gbr_layout module (DKMS registration,
# /usr/src/geforce-bar1-layout-*, or the plain /lib/modules/*/updates/gbr_layout.ko). Also removes what is left of
# 3080-20gb-rebar (rebar-arm.sh, rebar-arm.service, /etc/rebar-arm.conf, zz-nvidia-static-bar1.conf), for
# half-migrated hosts. A record unit still running is stopped first, after the udev rule is gone. Nothing is written
# to any GPU and no driver module is reloaded. Removed files are moved into a new timestamped backup; earlier backups
# are kept.
#
# Usage: sudo ./uninstall.sh [--dry-run] [--root DIR]
#   --dry-run    print what would be done, change nothing
#   --root DIR   uninstall from staging root DIR; no systemctl, dkms or depmod calls
set -u

NAME=geforce-bar1-resize
UNITS=("$NAME.service" rebar-arm.service)
OPTFILES=("/etc/modprobe.d/zz-$NAME.conf" /etc/modprobe.d/zz-nvidia-static-bar1.conf)
FILES=("/etc/systemd/system/$NAME.service" "/etc/systemd/system/$NAME.service.d" "/etc/systemd/system/$NAME-record@.service"
	"/usr/local/sbin/$NAME" "/etc/$NAME.conf" "/etc/$NAME"
	/etc/systemd/system/rebar-arm.service /etc/systemd/system/rebar-arm.service.d /usr/local/sbin/rebar-arm.sh /etc/rebar-arm.conf)
DRY=0 ROOT=""
die() { echo "uninstall: $*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "$0" | sed 1d; exit "${1:-0}"; }
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

opt_was=0
for f in "${OPTFILES[@]}"; do ! grep -qs '^[[:space:]]*options.*RMForceStaticBar1=0' "$ROOT$f" || opt_was=1; done
for u in "${UNITS[@]}"; do
	if [ -n "$ROOT" ]; then
		wants=$ROOT/etc/systemd/system/sysinit.target.wants/$u
		if [ -L "$wants" ]; then run rm "$wants"; echo "${did}removed enable link $wants"; fi
	elif systemctl cat "$u" >/dev/null 2>&1; then
		run systemctl disable "$u" || echo "systemctl disable $u failed"
	fi
done
[ -n "$ROOT" ] && echo "skipped: systemctl disable (--root; enable links removed)"

BACKUP=$ROOT/var/backups/$NAME/uninstall-$(date +%Y%m%d-%H%M%S)
remove() { # file: move it into the backup
	[ -e "$ROOT$1" ] || return 0
	run mkdir -p "$BACKUP$(dirname "$1")"
	run mv "$ROOT$1" "$BACKUP$1"
	echo "${did}removed $ROOT$1 (kept as $BACKUP$1)"
}
# A record unit may still be waiting RECORD_DELAY after a bind; when it wakes it writes the record and the driver option
# file again. So the udev rule goes first and udev reloads (no bind starts a new one), then running units are stopped.
remove "/etc/udev/rules.d/90-$NAME.rules"
if [ -n "$ROOT" ]; then
	echo "skipped: udevadm control --reload, systemctl stop $NAME-record@*.service (--root)"
else
	run udevadm control --reload 2>/dev/null || true
	run systemctl stop "$NAME-record@*.service" || echo "systemctl stop $NAME-record@*.service failed"
fi
for f in "${FILES[@]}"; do remove "$f"; done

# --- driver option file -----------------------------------------------------------------------------------------------
# Every key in it other than our RMForceStaticBar1=0 is the user's (a P2P opt-out, keys= from the config, keys merged
# from another file by --adopt-driver-line). A line that driver-option commented out in another file is restored;
# otherwise the user's keys stay in a minimal option file. Only one per-device line takes effect, so never both.
MARK='# adopted by geforce-bar1-resize: '
optvals() { sed -n 's/^[[:space:]]*options[[:space:]]\+nvidia[[:space:]].*NVreg_RegistryDwordsPerDevice="\{0,1\}\([^" ]*\).*/\1/p' "$@"; }
user_groups() { # NVreg_RegistryDwordsPerDevice values on stdin -> "pci=<address>;K=V;..." per group with keys besides ours
	local val t g keys
	local -a toks
	while IFS= read -r val; do
		IFS=';' read -r -a toks <<<"$val"
		g="" keys=""
		for t in "${toks[@]}"; do
			t=${t//[[:space:]]/}
			if [[ ${t,,} == pci=* ]]; then
				[ -z "$g" ] || [ -z "$keys" ] || echo "$g$keys"
				t=${t#*=} g="pci=${t,,};" keys=""
			elif [ -n "$t" ] && [ "$t" != RMForceStaticBar1=0 ]; then
				keys+="$t;"
			fi
		done
		[ -z "$g" ] || [ -z "$keys" ] || echo "$g$keys"
	done
}
# the current file, or on a host that was never migrated the old one (the current file already holds the old keys)
src=""
for f in "${OPTFILES[@]}"; do [ -n "$src" ] || [ ! -e "$ROOT$f" ] || src=$f; done
KEEP=()
[ -z "$src" ] || mapfile -t KEEP < <(optvals "$ROOT$src" | tail -n 1 | user_groups)
keepline=$(printf '%s' "${KEEP[@]}")
ADOPTED=() seen=" "
for d in /etc/modprobe.d /run/modprobe.d /usr/local/lib/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d; do
	for f in "$ROOT$d"/*.conf; do
		[ -f "$f" ] && grep -q "^$MARK" "$f" || continue
		p=$(readlink -f "$f")
		[[ $seen == *" $p "* ]] || { seen+="$p "; ADOPTED+=("$f"); }
	done
done
minimal="# Left by uninstall.sh of geforce-bar1-resize: the driver keys this file held besides RMForceStaticBar1=0.
# Delete this file if you no longer want them.
options nvidia NVreg_RegistryDwordsPerDevice=\"$keepline\""
as_is=0
[ ${#ADOPTED[@]} != 0 ] || [ -z "$keepline" ] || [ "$(cat "$ROOT${OPTFILES[0]}" 2>/dev/null)" != "$minimal" ] || as_is=1
for f in "${OPTFILES[@]}"; do
	[ "$f" != "${OPTFILES[0]}" ] || [ "$as_is" = 0 ] || continue
	remove "$f"
done
if [ ${#ADOPTED[@]} != 0 ]; then
	for f in "${ADOPTED[@]}"; do
		run mkdir -p "$BACKUP$(dirname "${f#"$ROOT"}")"
		run cp -a "$f" "$BACKUP${f#"$ROOT"}"
		run sed -i "s/^$MARK//" "$f"
		echo "${did}restored the NVreg_RegistryDwordsPerDevice line that driver-option had commented out in $f"
		echo "  (before: $BACKUP${f#"$ROOT"})"
	done
	declare -A HAVE=()
	while IFS= read -r g; do HAVE[${g%%;*}]+=";${g#*;}"; done < <(sed "s/^$MARK//" "${ADOPTED[@]}" | optvals | user_groups)
	lost=""
	for g in "${KEEP[@]}"; do
		IFS=';' read -r -a toks <<<"${g#*;}"
		for t in "${toks[@]}"; do [ -z "$t" ] || [[ ${HAVE[${g%%;*}]:-} == *";$t;"* ]] || lost+="${g%%;*};$t; "; done
	done
	[ -z "$lost" ] || printf '%s\n  %s\n' "not kept (only in $ROOT$src; add them to the restored line if you still want them):" "${lost% }"
elif [ -n "$keepline" ]; then
	if [ "$as_is" = 1 ]; then
		printf '%s\n  %s\n' "kept $ROOT${OPTFILES[0]} as it is: it holds only your driver keys" "$keepline"
	elif [ "$DRY" = 1 ]; then
		printf '%s\n  %s\n' "would write $ROOT${OPTFILES[0]} with only your driver keys (RMForceStaticBar1=0 removed):" "$keepline"
	else
		mkdir -p "$ROOT$(dirname "${OPTFILES[0]}")" && printf '%s\n' "$minimal" >"$ROOT${OPTFILES[0]}" && chmod 0644 "$ROOT${OPTFILES[0]}" ||
			die "cannot write ${OPTFILES[0]}; your driver keys were:"$'\n'"  $keepline"
		printf '%s\n  %s\n' "kept your driver keys in $ROOT${OPTFILES[0]} (RMForceStaticBar1=0 removed):" "$keepline"
	fi
fi

# layout module, new and old names: DKMS first (it removes the built .ko from every kernel), then any leftovers
for pkg in geforce-bar1-layout rebar-layout; do
	for d in "$ROOT"/usr/src/"$pkg"-*; do
		[ -d "$d" ] || continue
		if [ -z "$ROOT" ] && command -v dkms >/dev/null; then
			run dkms remove "$pkg/${d##*/"$pkg"-}" --all || echo "dkms remove $pkg/${d##*/"$pkg"-} failed (not registered?)"
		elif [ -n "$ROOT" ]; then
			echo "skipped: dkms remove $pkg/${d##*/"$pkg"-} (--root)"
		fi
		run mkdir -p "$BACKUP/usr/src"
		run mv "$d" "$BACKUP/usr/src/"
		echo "${did}removed $d (kept under $BACKUP/usr/src)"
	done
done
depmod_krels=()
for ko in "$ROOT"/lib/modules/*/updates/gbr_layout.ko "$ROOT"/lib/modules/*/updates/dkms/gbr_layout.ko* \
	"$ROOT"/lib/modules/*/updates/rebar_layout.ko "$ROOT"/lib/modules/*/updates/dkms/rebar_layout.ko*; do
	[ -e "$ko" ] || continue
	rel=${ko#"$ROOT"/lib/modules/}
	run mkdir -p "$BACKUP$(dirname "${ko#"$ROOT"}")"
	run mv "$ko" "$BACKUP${ko#"$ROOT"}"
	echo "${did}removed $ko (kept as $BACKUP${ko#"$ROOT"})"
	[[ " ${depmod_krels[*]} " == *" ${rel%%/*} "* ]] || depmod_krels+=("${rel%%/*}")
done
for krel in "${depmod_krels[@]}"; do
	if [ -n "$ROOT" ]; then echo "skipped: depmod -a $krel (--root)"; else run depmod -a "$krel"; fi
done

if [ -n "$ROOT" ]; then
	echo "skipped: systemctl daemon-reload (--root)"
else
	run systemctl daemon-reload
fi

echo
echo "Backups are kept under $ROOT/var/backups/$NAME/:"
find "$ROOT/var/backups/$NAME" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | sed 's/^/  /'
echo "Log kept: /var/log/$NAME.log"
echo
echo "BAR1 IS STILL LARGE. Uninstalling changes no GPU: every enlarged card keeps its BAR1 (and an armed 0x610)"
echo "until the next reboot, or until the manual live rollback (docs/manual-procedure.md: shrink with"
echo "resource1_resize first, then write 0x610 back to its stock value)."
if [ "$opt_was" = 1 ]; then
	echo "The driver option RMForceStaticBar1=0 stays active in the loaded nvidia module until the next reboot or"
	echo "driver reload (docs/driver-option.md)."
fi
