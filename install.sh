#!/bin/bash
# Install the BAR1 size override boot service: /etc/rebar-arm.conf, /usr/local/sbin/rebar-arm.sh,
# /etc/systemd/system/rebar-arm.service and, for the verified card, the NVIDIA driver option file
# /etc/modprobe.d/zz-nvidia-static-bar1.conf. Nothing is written to any GPU, and no driver module is loaded or
# unloaded.
#
# Usage: sudo ./install.sh [options]
#   --bdfs "BDF ..."    cards to arm (full or short PCI addresses); asked interactively if omitted
#   --n N               BAR1 = 64 MiB << N (default 9 = 32 GiB, the only verified value)
#   --include-console   also arm a card that drives the console (left out by default)
#   --force             continue when rebar-check.sh reports failed preconditions or untested ids
#   --enable            run `systemctl enable rebar-arm.service` (default: only print the command)
#   --dry-run           print what would be done, change nothing
#   --root DIR          install into staging root DIR; no systemctl calls
#   --lift-ceiling      install the driver option RMForceStaticBar1=0 for the armed cards even if they are not
#                       the verified card (RTX 3080 20GB, 10de:2206 subsystem 10de:146d)
#   --no-lift-ceiling   do not install the driver option (installed by default for the verified card)
set -u

echo "DISCLAIMER: use at your own risk; provided as is, without warranty (MIT). Writing GPU PCI config registers can hang a GPU or the host."
echo "No firmware is flashed and the change is volatile, but the risk is not zero. Read the scripts first. Not affiliated with NVIDIA."

SRC=$(cd "$(dirname "$0")" && pwd)
UNIT=rebar-arm.service
CONF=/etc/rebar-arm.conf
SCRIPT=/usr/local/sbin/rebar-arm.sh
UNITFILE=/etc/systemd/system/$UNIT
VERIFIED_IDS="10de:2206"
VERIFIED_SUBSYS="10de:146d"   # 10de:2206 alone is also the stock RTX 3080 10GB
LIFTFILE=/etc/modprobe.d/zz-nvidia-static-bar1.conf
VERIFIED_DRIVER=615.71.09

BDFS="" N="" INCLUDE_CONSOLE=0 FORCE=0 ENABLE=0 DRY=0 ROOT="" LIFT=auto
die() { echo "install: $*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/{/^#/p}' "$0"; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
	case $1 in
		--bdfs) [ $# -ge 2 ] || usage 2; BDFS=$2; shift 2 ;;
		--n) [ $# -ge 2 ] || usage 2; N=$2; shift 2 ;;
		--include-console) INCLUDE_CONSOLE=1; shift ;;
		--force) FORCE=1; shift ;;
		--enable) ENABLE=1; shift ;;
		--dry-run) DRY=1; shift ;;
		--root) [ $# -ge 2 ] || usage 2; ROOT=${2%/}; shift 2 ;;
		--lift-ceiling) LIFT=1; shift ;;
		--no-lift-ceiling) LIFT=0; shift ;;
		-h | --help) usage 0 ;;
		*) echo "install: unknown option $1" >&2; usage 2 ;;
	esac
done
[ -z "$ROOT" ] || [ -d "$ROOT" ] || die "--root $ROOT is not a directory"

run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }

# --- requirements ---------------------------------------------------------------------------------
if [ "$(id -u)" != 0 ]; then
	[ -n "$ROOT" ] || [ "$DRY" = 1 ] || die "needs root (or use --dry-run / --root DIR to stage)"
	echo "note: not root; staging only"
fi
for tool in setpci lspci; do
	command -v "$tool" >/dev/null || die "$tool not found: install pciutils"
done

drives_console() {
	local dev fb
	dev=$(readlink -f "/sys/bus/pci/devices/$1")
	[ "$(cat "$dev/boot_vga" 2>/dev/null)" = 1 ] && return 0
	for fb in /sys/class/graphics/fb*; do
		[ "$(readlink -f "$fb/device" 2>/dev/null)" = "$dev" ] && return 0
	done
	return 1
}

echo "NVIDIA GPUs:"
GPUS=()
for dev in /sys/bus/pci/devices/*; do
	[ "$(cat "$dev/vendor")" = 0x10de ] && [[ $(cat "$dev/class") == 0x03* ]] || continue
	bdf=${dev##*/}
	GPUS+=("$bdf")
	id="$(cat "$dev/vendor"):$(cat "$dev/device")"
	drv=$( [ -e "$dev/driver" ] && basename "$(readlink -f "$dev/driver")" || echo none)
	con=""; drives_console "$bdf" && con="  <- drives the console"
	echo "  $bdf  ${id//0x/}  driver $drv$con"
done
[ ${#GPUS[@]} -gt 0 ] || die "no NVIDIA display device found"

# --- choose cards ---------------------------------------------------------------------------------
if [ -z "$BDFS" ]; then
	[ -t 0 ] || die "no --bdfs given and stdin is not a terminal"
	read -r -p "Cards to arm (space-separated addresses from the list above): " BDFS
fi
SEL=()
for bdf in $BDFS; do
	case $bdf in ????:*) ;; *) bdf=0000:$bdf ;; esac
	bdf=${bdf,,}
	[ -e "/sys/bus/pci/devices/$bdf" ] || die "$bdf: no such PCI device"
	[[ " ${GPUS[*]} " == *" $bdf "* ]] || die "$bdf is not an NVIDIA display device"
	[ -e "/sys/bus/pci/devices/$bdf/resource1_resize" ] \
		|| die "kernel does not expose /sys/bus/pci/devices/$bdf/resource1_resize (needs sysfs ReBAR support)"
	[[ " ${SEL[*]} " == *" $bdf "* ]] && { echo "note: $bdf given twice, using it once"; continue; }
	SEL+=("$bdf")
done
[ ${#SEL[@]} -gt 0 ] || die "no cards selected"

# --- compatibility check (read-only) --------------------------------------------------------------
echo
echo "Running scripts/rebar-check.sh ${SEL[*]}"
if "$SRC/scripts/rebar-check.sh" "${SEL[@]}" </dev/null; then
	echo "Preconditions hold."
elif [ "$FORCE" = 1 ]; then
	echo "WARNING: preconditions not confirmed (see above); continuing because of --force"
else
	die "preconditions not confirmed (see above); fix them or rerun with --force"
fi

IDS=$VERIFIED_IDS
CARDS=()
for bdf in "${SEL[@]}"; do
	dev=/sys/bus/pci/devices/$bdf
	id="$(cat "$dev/vendor"):$(cat "$dev/device")"; id=${id//0x/}
	if [[ " $IDS " != *" $id "* ]]; then
		[ "$FORCE" = 1 ] || die "$bdf is $id, not a verified id ($VERIFIED_IDS); rerun with --force to allow it"
		echo "WARNING: $bdf is $id, untested; added to REBAR_IDS because of --force"
		IDS="$IDS $id"
	fi
	if drives_console "$bdf" && [ "$INCLUDE_CONSOLE" = 0 ]; then
		echo "Leaving out $bdf: it drives the console. Arm it by hand first (README, manual procedure);"
		echo "  once that works, rerun with --include-console."
		continue
	fi
	CARDS+=("$bdf")
done
[ ${#CARDS[@]} -gt 0 ] || die "no cards left to arm"

# --- size -----------------------------------------------------------------------------------------
if [ -z "$N" ]; then
	if [ -t 0 ]; then
		echo "BAR1 = 64 MiB << n, n = ceil(log2(VRAM / 64 MiB)); scripts/rebar-check.sh --vram SIZE suggests it."
		read -r -p "n [9 = 32 GiB, verified on RTX 3080 20GB only]: " N
	fi
	N=${N:-9}
fi
[[ $N =~ ^([0-9]|1[0-3])$ ]] || die "--n must be 0..13"
[ "$N" = 9 ] || echo "WARNING: n = $N is predicted, not tested; only n = 9 is verified"

# --- write files ----------------------------------------------------------------------------------
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=$ROOT/var/backups/rebar-arm/$STAMP
RESTORE=()
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

put() { # src dest mode
	local dest=$ROOT$2 did=""
	[ "$DRY" = 1 ] && did="would be "
	if [ -e "$dest" ]; then
		if cmp -s "$1" "$dest"; then echo "unchanged $dest"; return; fi
		run mkdir -p "$BACKUP$(dirname "$2")"
		run cp -a "$dest" "$BACKUP$2"
		RESTORE+=("cp -a $BACKUP$2 $dest")
		echo "${did}backed up $dest -> $BACKUP$2"
	fi
	run install -D -m "$3" "$1" "$dest"
	echo "${did}installed $dest"
}

cat >"$TMP/conf" <<EOF
# $CONF, written by install.sh. Sourced by rebar-arm.sh (bash syntax).
# Leave a console-driving card out until a manual run has worked on it.
REBAR_BDFS="${CARDS[*]}"
REBAR_IDS="$IDS"
# BAR1 = 64 MiB << REBAR_N. 9 (32 GiB) is the only verified value (RTX 3080 20GB).
REBAR_N=$N
REBAR_LOG=/var/log/rebar-arm.log
EOF
cp "$SRC/systemd/$UNIT" "$TMP/unit"
grep -q '^TimeoutStartSec=' "$TMP/unit" || sed -i '/^RemainAfterExit=/a TimeoutStartSec=60' "$TMP/unit"

echo
echo "Config to write:"
sed 's/^/  /' "$TMP/conf"
put "$TMP/conf" "$CONF" 0644
put "$SRC/scripts/rebar-arm.sh" "$SCRIPT" 0755
put "$TMP/unit" "$UNITFILE" 0644

# --- driver option: RMForceStaticBar1=0 per armed card -------------------------------------------
# Verified card = vendor:device 10de:2206 and subsystem 10de:146d, read from the card's sysfs files
# vendor, device, subsystem_vendor and subsystem_device.
if [ "$LIFT" = auto ]; then
	LIFT=1
	for bdf in "${CARDS[@]}"; do
		dev=/sys/bus/pci/devices/$bdf
		id="$(cat "$dev/vendor"):$(cat "$dev/device")"; id=${id//0x/}
		sub="$(cat "$dev/subsystem_vendor"):$(cat "$dev/subsystem_device")"; sub=${sub//0x/}
		[ "$id" = "$VERIFIED_IDS" ] && [ "$sub" = "$VERIFIED_SUBSYS" ] || LIFT=0
	done
	[ "$LIFT" = 1 ] || echo "Driver option not installed: not every armed card is $VERIFIED_IDS subsystem $VERIFIED_SUBSYS (--lift-ceiling installs it anyway)."
fi
if [ "$LIFT" = 1 ]; then
	echo
	echo "Driver option RMForceStaticBar1=0 for: ${CARDS[*]}"
	if [ -n "$ROOT" ]; then
		echo "skipped: driver version check (--root)"
	else
		drv=$(grep -oE 'Kernel Module +[0-9.]+' /proc/driver/nvidia/version 2>/dev/null | awk '{print $3}')
		[ -n "$drv" ] || drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)
		if [ -z "$drv" ]; then
			echo "WARNING: NVIDIA driver version unknown (driver not loaded?); the option is verified only on $VERIFIED_DRIVER"
		elif [ "$drv" != "$VERIFIED_DRIVER" ]; then
			echo "WARNING: NVIDIA driver $drv; the option is verified only on $VERIFIED_DRIVER"
		else
			echo "driver $drv: the verified version"
		fi
	fi
	for f in "$ROOT"/etc/modprobe.d/*.conf "$ROOT"/run/modprobe.d/*.conf "$ROOT"/usr/lib/modprobe.d/*.conf; do
		[ -e "$f" ] && [ "$f" != "$ROOT$LIFTFILE" ] || continue
		if grep -qE 'NVreg_RegistryDwords(PerDevice)?=' "$f"; then
			echo "WARNING: $f also sets NVreg_RegistryDwords or NVreg_RegistryDwordsPerDevice. A global setting applies to every"
			echo "  GPU, and of two per-device lines only the last counts: keep one per-device line listing every card."
		fi
	done
	perdev=""
	for bdf in "${CARDS[@]}"; do perdev+="pci=$bdf;RMForceStaticBar1=0;"; done
	cat >"$TMP/lift" <<EOF
# Written by install.sh (3080-20gb-rebar). Turns off the NVIDIA driver's static BAR1 mapping on the listed cards
# only (one pci=<BDF> entry per card, lspci -D form), so host-visible allocations can reach almost all of VRAM.
# Verified on driver 615.71.09. Read at the next load of the nvidia module. To remove: delete this file
# (uninstall.sh does), then reboot. If the nvidia module is in your initramfs, rebuild the initramfs too.
options nvidia NVreg_RegistryDwordsPerDevice="$perdev"
EOF
	put "$TMP/lift" "$LIFTFILE" 0644
	if [ -z "$ROOT" ] && command -v lsinitramfs >/dev/null \
		&& lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null | grep -qE '/nvidia\.ko'; then
		echo "note: the nvidia module is in the initramfs; run update-initramfs -u so the option applies at boot"
	fi
	echo "No driver module was reloaded. The option applies at the next load of the nvidia module (reboot)."
elif [ -e "$ROOT$LIFTFILE" ]; then
	echo "note: existing $ROOT$LIFTFILE left unchanged (delete it, or run uninstall.sh, to remove the option)"
fi

if [ -n "$ROOT" ]; then
	echo "skipped: systemctl daemon-reload (--root)"
else
	run systemctl daemon-reload
fi
if [ "$ENABLE" = 1 ] && [ -z "$ROOT" ]; then
	run systemctl enable "$UNIT"
elif [ "$ENABLE" = 1 ]; then
	echo "skipped: systemctl enable (--root)"
fi
if [ -n "$ROOT" ]; then
	state=disabled
	[ -L "$ROOT/etc/systemd/system/sysinit.target.wants/$UNIT" ] && state=enabled
else
	state=$(systemctl is-enabled "$UNIT" 2>/dev/null) || true
fi
echo "Unit state now: ${state:-unknown}$([ "$DRY" = 1 ] && echo " (dry-run: nothing was changed)")"
[ "$state" = enabled ] || echo "To arm at every boot: systemctl enable $UNIT"
[ -d "$ROOT$UNITFILE.d" ] && echo "note: drop-in directory $ROOT$UNITFILE.d exists and overrides parts of the unit"

echo
if [ ${#RESTORE[@]} -gt 0 ]; then
	echo "Replaced files are kept in $BACKUP. To restore them:"
	printf '  %s\n' "${RESTORE[@]}"
fi
echo "Nothing was written to any GPU. The service acts at the next boot (if enabled), before the driver binds."
echo "After reboot check: journalctl -b -u $UNIT; nvidia-smi -q -d MEMORY | grep -A1 BAR1"
