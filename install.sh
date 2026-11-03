#!/bin/bash
# SPDX-License-Identifier: MIT
# Install geforce-bar1-resize: /usr/local/sbin/geforce-bar1-resize, /etc/geforce-bar1-resize.conf, the boot unit
# geforce-bar1-resize.service, the VRAM record unit geforce-bar1-resize-record@.service with its udev rule, and the
# NVIDIA driver option file /etc/modprobe.d/zz-geforce-bar1-resize.conf. Optionally the gbr_layout kernel module for
# cards behind a PCIe switch (kernel/gbr_layout, GPL-2.0-only OR MIT), via DKMS when installed. Migrates an install
# of 3080-20gb-rebar (rebar-arm.sh) on the way (docs/migration.md). Nothing is written to any GPU, and no driver
# module is loaded or unloaded. Running it again changes nothing.
#
# Usage: sudo ./install.sh [options]
#   --cards auto|"BDF ..."    cards to enlarge (default: auto, every qualifying NVIDIA card)
#   --exclude SEL             never touch SEL (BDF, vendor:device or vendor:device/subvendor:subdevice); repeatable
#   --size auto|N|SIZE        BAR1 size: auto (>= VRAM), n 0..13, or 64M..512G
#   --route auto|resize|0x610|skip
#   --layout off|auto|dryrun|force
#                             cards behind a PCIe switch (experimental, default off); auto/dryrun/force build the
#                             gbr_layout module when a card sits behind a switch
#   --layout-module           build and install the gbr_layout module in any case (needs the kernel headers)
#   --driver-option auto|on|off
#                             RMForceStaticBar1=0: auto (default) for cards enlarged through 0x610, on for every card
#                             with a large BAR1 (resize-only cards otherwise keep static BAR1, which some P2P setups
#                             need), off for none
#   --console include|skip    the card that drives the console (default include)
#   --adopt-driver-line       merge another modprobe.d file's NVreg_RegistryDwordsPerDevice line into ours and
#                             comment it out (without it, such a line stops the install)
#   --enable                  systemctl enable geforce-bar1-resize.service (default: only print the command, unless
#                             a migrated rebar-arm.service was enabled)
#   --yes                     do not ask before installing (needed when stdin is not a terminal)
#   --dry-run                 print the plan and what would be done, change nothing
#   --root DIR                install into staging root DIR; no systemctl, dkms or depmod calls
# Without config options an existing /etc/geforce-bar1-resize.conf is kept; with them, only those keys change.
# Old options (one release): --bdfs, --n, --resize-only, --layout without a value, --layout-dryrun, --lift-ceiling,
# --no-lift-ceiling, --include-console, --force; each prints its replacement.
set -u

echo "DISCLAIMER: use at your own risk; provided as is, without warranty (MIT)."
echo "Writing GPU PCI config registers can hang a GPU or the host. No firmware is flashed and the change is volatile,"
echo "but the risk is not zero. Read the scripts first. Not affiliated with NVIDIA."

SRC=$(cd "$(dirname "$0")" && pwd)
NAME=geforce-bar1-resize
UNIT=$NAME.service
RUNIT=$NAME-record@.service
CONF=/etc/$NAME.conf
SCRIPT=/usr/local/sbin/$NAME
UNITFILE=/etc/systemd/system/$UNIT
RUNITFILE=/etc/systemd/system/$RUNIT
RULE=/etc/udev/rules.d/90-$NAME.rules
STATE=/etc/$NAME
MODNAME=gbr_layout
DKMSNAME=geforce-bar1-layout
MODSRC=$SRC/kernel/gbr_layout
MODFILES=(gbr_layout.c Kbuild Makefile dkms.conf)
# 3080-20gb-rebar: any of these means an old install to migrate
OLD_UNIT=rebar-arm.service
OLD_CONF=/etc/rebar-arm.conf
OLD_SCRIPT=/usr/local/sbin/rebar-arm.sh
OLD_UNITFILE=/etc/systemd/system/$OLD_UNIT
OLD_OPTFILE=/etc/modprobe.d/zz-nvidia-static-bar1.conf

CARDS="" EXCL=() SIZE="" ROUTE="" LAYOUT="" DOPT="" CONSOLE="" BUILD=0 ADOPT=0 ENABLE=0 YES=0 DRY=0 ROOT=""
KREL=$(uname -r)
die() { echo "install: $*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "$0" | sed 1d; exit "${1:-0}"; }
old() { echo "note: $1 is deprecated; use $2"; }
while [ $# -gt 0 ]; do
	case $1 in
		--cards) [ $# -ge 2 ] || usage 2; CARDS=$2; shift 2 ;;
		--exclude) [ $# -ge 2 ] || usage 2; EXCL+=("$2"); shift 2 ;;
		--size) [ $# -ge 2 ] || usage 2; SIZE=$2; shift 2 ;;
		--route) [ $# -ge 2 ] || usage 2; ROUTE=$2; shift 2 ;;
		--layout)
			case ${2:-} in
				off | auto | dryrun | force) LAYOUT=$2; shift 2 ;;
				*) old --layout "--layout auto --layout-module"; LAYOUT=auto BUILD=1; shift ;;
			esac ;;
		--layout-module) BUILD=1; shift ;;
		--driver-option) [ $# -ge 2 ] || usage 2; DOPT=$2; shift 2 ;;
		--console) [ $# -ge 2 ] || usage 2; CONSOLE=$2; shift 2 ;;
		--adopt-driver-line) ADOPT=1; shift ;;
		--enable) ENABLE=1; shift ;;
		--yes) YES=1; shift ;;
		--dry-run) DRY=1; shift ;;
		--root) [ $# -ge 2 ] || usage 2; ROOT=${2%/}; shift 2 ;;
		--bdfs) [ $# -ge 2 ] || usage 2; old --bdfs --cards; CARDS=$2; shift 2 ;;
		--n) [ $# -ge 2 ] || usage 2; old --n --size; SIZE=$2; shift 2 ;;
		--resize-only) old --resize-only "--route resize"; ROUTE=resize; shift ;;
		--layout-dryrun) old --layout-dryrun "--layout dryrun --layout-module"; LAYOUT=dryrun BUILD=1; shift ;;
		--lift-ceiling) old --lift-ceiling "--driver-option auto"; DOPT=auto; shift ;;
		--no-lift-ceiling) old --no-lift-ceiling "--driver-option off"; DOPT=off; shift ;;
		--include-console) old --include-console "nothing (the console card is included by default)"; shift ;;
		--force) old --force "nothing (the structural checks decide)"; shift ;;
		-h | --help) usage 0 ;;
		*) echo "install: unknown option $1" >&2; usage 2 ;;
	esac
done
[ -z "$ROOT" ] || [ -d "$ROOT" ] || die "--root $ROOT is not a directory"
case $ROUTE in "" | auto | resize | 0x610 | skip) ;; *) die "--route must be auto, resize, 0x610 or skip" ;; esac
case $LAYOUT in "" | off | auto | dryrun | force) ;; *) die "--layout must be off, auto, dryrun or force" ;; esac
case $DOPT in "" | auto | on | off) ;; *) die "--driver-option must be auto, on or off" ;; esac
case $CONSOLE in "" | include | skip) ;; *) die "--console must be include or skip" ;; esac
# the script's size_n: 0..13, or 64M..512G
if [ -n "$SIZE" ] && [ "$SIZE" != auto ] && [[ ! $SIZE =~ ^([0-9]|1[0-3])$ ]]; then
	mib=0
	if [[ ${SIZE^^} =~ ^([0-9]{1,7})(G|GB|GIB)$ ]]; then mib=$((10#${BASH_REMATCH[1]} * 1024))
	elif [[ ${SIZE^^} =~ ^([0-9]{1,10})(M|MB|MIB)$ ]]; then mib=$((10#${BASH_REMATCH[1]})); fi
	[ "$mib" -ge 64 ] && [ "$mib" -le $((512 << 10)) ] || die "--size must be auto, 0..13 or 64M..512G"
fi
# Every value install.sh writes into the root-sourced config must have one of these shapes (no quotes, $, backticks)
BDF_RE='^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$'
SEL_RE='^(([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]|[0-9a-fA-F]{4}:[0-9a-fA-F]{4}(/[0-9a-fA-F]{4}:[0-9a-fA-F]{4})?)$'
KEYS_RE='^([A-Za-z][A-Za-z0-9_]*=(0[xX][0-9a-fA-F]+|[0-9]+);)+$'
all_match() { # regex "word list": every word matches (split without pathname expansion)
	local re=$1 w
	local -a ws
	read -r -a ws <<<"$2"
	for w in "${ws[@]}"; do [[ $w =~ $re ]] || return 1; done
}
[ -z "$CARDS" ] || [ "$CARDS" = auto ] || all_match "$BDF_RE" "$CARDS" || die "--cards must be auto or PCI addresses (0000:01:00.0)"
[ ${#EXCL[@]} = 0 ] || all_match "$SEL_RE" "${EXCL[*]}" || die "--exclude takes a PCI address, vendor:device or vendor:device/subvendor:subdevice"

run() { if [ "$DRY" = 1 ]; then echo "  [dry-run] $*"; else "$@"; fi; }
did=""; [ "$DRY" = 1 ] && did="would be "

# --- requirements ---------------------------------------------------------------------------------
# the plan and the driver option read each card's extended config space, which setpci can only read as root (also
# for --dry-run and --root: otherwise every card would look like one without a Resizable BAR capability)
[ "$(id -u)" = 0 ] || { echo "install: run as root (setpci cannot read extended config space otherwise)" >&2; exit 2; }
for tool in setpci lspci; do
	command -v "$tool" >/dev/null || die "$tool not found: install pciutils"
done

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=$ROOT/var/backups/$NAME/$STAMP
RESTORE=()
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
GBR=$SRC/scripts/$NAME

# --- 3080-20gb-rebar install? (docs/migration.md) ---------------------------------------------------------
OLD_FILES=()
for f in "$OLD_CONF" "$OLD_SCRIPT" "$OLD_UNITFILE" "$OLD_UNITFILE.d" "/etc/systemd/system/sysinit.target.wants/$OLD_UNIT" "$OLD_OPTFILE"; do
	[ ! -e "$ROOT$f" ] && [ ! -L "$ROOT$f" ] || OLD_FILES+=("$f")
done
OLD_MODS=()
for f in "$ROOT"/usr/src/rebar-layout-* "$ROOT"/lib/modules/*/updates/rebar_layout.ko "$ROOT"/lib/modules/*/updates/dkms/rebar_layout.ko*; do
	[ ! -e "$f" ] || OLD_MODS+=("${f#"$ROOT"}")
done
OLD_DKMS=""
[ -n "$ROOT" ] || ! command -v dkms >/dev/null || OLD_DKMS=$(dkms status rebar-layout 2>/dev/null | sed -n 's|^rebar-layout/\([^,: ]*\).*|\1|p' | sort -u | tr '\n' ' ')
MIGRATE=0
[ ${#OLD_FILES[@]} = 0 ] && [ ${#OLD_MODS[@]} = 0 ] && [ -z "$OLD_DKMS" ] || MIGRATE=1
OLD_ENABLED=0
if [ "$MIGRATE" = 1 ]; then
	echo
	echo "Found an install of 3080-20gb-rebar:"
	printf '  %s\n' "${OLD_FILES[@]}" "${OLD_MODS[@]}" ${OLD_DKMS:+"dkms rebar-layout/$OLD_DKMS"}
	if [ -n "$ROOT" ]; then
		[ -L "$ROOT/etc/systemd/system/sysinit.target.wants/$OLD_UNIT" ] && OLD_ENABLED=1
	else
		[ "$(systemctl is-enabled "$OLD_UNIT" 2>/dev/null)" = enabled ] && OLD_ENABLED=1
	fi
fi
# A migration stopped after it began disabling and moving the old install left $STATE/migrating (removed with its
# last step): finish it, and enable the new unit if the old one was enabled. Nothing else turns this on: a missing
# $STATE/migrated alone (e.g. /etc/geforce-bar1-resize deleted) is not an interrupted migration.
RESUME=0
if [ -e "$ROOT$STATE/migrating" ]; then
	RESUME=1
	grep -qx 'rebar-arm.service was enabled.' "$ROOT$STATE/migrating" && OLD_ENABLED=1
	echo "An earlier migration from 3080-20gb-rebar did not finish ($STATE/migrating); finishing it."
	[ "$OLD_ENABLED" = 0 ] || echo "rebar-arm.service was enabled, so $UNIT is enabled at the end."
fi

# --- config -----------------------------------------------------------------------------------------
# set_key FILE KEY VALUE: replace the KEY= line, or add it before the CARD block (at the end when there is none)
set_key() {
	local v=$3
	[[ $v != *[[:space:]]* && -n $v ]] || v="\"$v\""
	if grep -q "^$2=" "$1"; then
		local esc=${v//\\/\\\\}; esc=${esc//&/\\&}; esc=${esc//|/\\|}
		sed -i "s|^$2=.*|$2=$esc|" "$1"
	elif grep -q '^declare -A CARD=($' "$1"; then
		sed -i "/^declare -A CARD=($/i $2=$v" "$1"
	else
		printf '%s=%s\n' "$2" "$v" >>"$1"
	fi
}
CONF_FROM=""
if [ -e "$ROOT$CONF" ]; then
	cp "$ROOT$CONF" "$TMP/conf"
	CONF_FROM=existing
else
	cat >"$TMP/conf" <<EOF
# SPDX-License-Identifier: MIT
# $CONF, written by install.sh. Sourced by $NAME (bash syntax).
# Every key and the per-card CARD[] entries: config/$NAME.conf.example, docs/configuration.md.
CARDS=auto
EXCLUDE=""
SIZE=auto
ROUTE=auto
LAYOUT=off
DRIVER_OPTION=auto
CONSOLE=include
LOG=/var/log/$NAME.log
RECORD_DELAY=60
declare -A CARD=(
)
EOF
	CONF_FROM=new
fi
# map the old config (REBAR_* keys, docs/configuration.md); its REBAR_BDFS stays the explicit card list
if [ "$MIGRATE" = 1 ] && [ -e "$ROOT$OLD_CONF" ]; then
	# shellcheck disable=SC1090
	mapfile -t oldv < <(
		unset REBAR_BDFS REBAR_N REBAR_ARM REBAR_LAYOUT
		. "$ROOT$OLD_CONF" >/dev/null 2>&1
		echo "${REBAR_BDFS-}"; echo "${REBAR_N-9}"; echo "${REBAR_ARM-0x610}"; echo "${REBAR_LAYOUT-off}"
	)
	if [ "$CONF_FROM" = new ]; then
		# refuse what the schema does not allow rather than source it at every boot (nothing is written yet)
		again="  fix it (or remove the line) and rerun. Nothing was written"
		[ -z "${oldv[0]}" ] || all_match "$BDF_RE" "${oldv[0]}" || die "$OLD_CONF: REBAR_BDFS=\"${oldv[0]}\" is not a list of PCI addresses"$'\n'"$again"
		[[ ${oldv[1]} =~ ^([0-9]|1[0-3])$ ]] || die "$OLD_CONF: REBAR_N=${oldv[1]} is not 0..13"$'\n'"$again"
		case ${oldv[3]} in off | auto | dryrun | force) ;; *) die "$OLD_CONF: REBAR_LAYOUT=${oldv[3]} is not off, auto, dryrun or force"$'\n'"$again" ;; esac
		echo "Mapping $OLD_CONF: REBAR_BDFS -> CARDS, REBAR_N -> SIZE, REBAR_ARM -> ROUTE, REBAR_LAYOUT -> LAYOUT"
		[ -z "${oldv[0]}" ] || set_key "$TMP/conf" CARDS "${oldv[0]}"
		set_key "$TMP/conf" SIZE "${oldv[1]}"
		case ${oldv[2]} in none) set_key "$TMP/conf" ROUTE resize ;; esac
		set_key "$TMP/conf" LAYOUT "${oldv[3]}"
		# the old installer wrote the driver option only for some cards; no old option file means it was off
		[ -e "$ROOT$OLD_OPTFILE" ] || set_key "$TMP/conf" DRIVER_OPTION off
	else
		echo "note: $CONF exists; $OLD_CONF is not mapped into it"
		echo "  $OLD_CONF has CARDS=\"${oldv[0]}\" SIZE=${oldv[1]}"
	fi
fi
[ -z "$CARDS" ] || set_key "$TMP/conf" CARDS "$CARDS"
[ ${#EXCL[@]} = 0 ] || set_key "$TMP/conf" EXCLUDE "${EXCL[*]}"
[ -z "$SIZE" ] || set_key "$TMP/conf" SIZE "$SIZE"
[ -z "$ROUTE" ] || set_key "$TMP/conf" ROUTE "$ROUTE"
[ -z "$LAYOUT" ] || set_key "$TMP/conf" LAYOUT "$LAYOUT"
[ -z "$DOPT" ] || set_key "$TMP/conf" DRIVER_OPTION "$DOPT"
[ -z "$CONSOLE" ] || set_key "$TMP/conf" CONSOLE "$CONSOLE"
# old option file: user keys become per-card keys= (with ids=, so the entry is ignored if another card sits there)
if [ "$MIGRATE" = 1 ] && [ -e "$ROOT$OLD_OPTFILE" ]; then
	val=$(sed -n 's/^[[:space:]]*options[[:space:]]\+nvidia[[:space:]].*NVreg_RegistryDwordsPerDevice="\{0,1\}\([^" ]*\).*/\1/p' "$ROOT$OLD_OPTFILE" | tail -n 1)
	IFS=';' read -r -a toks <<<"$val"
	bdf="" keys=""
	addcard() {
		local ids d=/sys/bus/pci/devices/$1
		[ -n "$1" ] && [ -n "$2" ] || return 0
		[[ $1 =~ $BDF_RE ]] || die "$OLD_OPTFILE: pci=$1 is not a PCI address"$'\n'"  fix the line and rerun. Nothing was written"
		[[ $2 =~ $KEYS_RE ]] || die "$OLD_OPTFILE: the keys '$2' for $1 are not K=V; tokens with a decimal or 0x value"$'\n'"  fix the line and rerun. Nothing was written"
		grep -qE "^[[:space:]]*(CARD)?\[$1\]=" "$TMP/conf" && { echo "note: CARD[$1] exists; keys $2 from $OLD_OPTFILE not added"; return 0; }
		ids="$(cat "$d/vendor" 2>/dev/null):$(cat "$d/device" 2>/dev/null)/$(cat "$d/subsystem_vendor" 2>/dev/null):$(cat "$d/subsystem_device" 2>/dev/null)"
		ids=${ids//0x/}
		[[ $ids =~ ^[0-9a-f]{4}:[0-9a-f]{4}/[0-9a-f]{4}:[0-9a-f]{4}$ ]] || ids=""
		# into the multi-line CARD block when there is one; otherwise a plain assignment at the end (the script
		# declares CARD before it sources the config)
		if grep -q '^declare -A CARD=($' "$TMP/conf"; then
			sed -i "/^declare -A CARD=($/a \\	[$1]=\"${ids:+ids=$ids }keys=$2\"" "$TMP/conf"
		else
			printf 'CARD[%s]="%skeys=%s"\n' "$1" "${ids:+ids=$ids }" "$2" >>"$TMP/conf"
		fi
		echo "Driver keys $2 for $1 kept as CARD[$1] in $CONF"
	}
	for t in "${toks[@]}"; do
		t=${t//[[:space:]]/}
		if [[ ${t,,} == pci=* ]]; then addcard "$bdf" "$keys"; bdf=${t#*=} bdf=${bdf,,} keys=""
		elif [ -n "$t" ] && [ "$t" != RMForceStaticBar1=0 ]; then keys+="$t;"; fi
	done
	addcard "$bdf" "$keys"
fi
bash -n "$TMP/conf" || die "the config would not parse (see above); nothing written"
echo
if [ "$CONF_FROM" = existing ] && cmp -s "$TMP/conf" "$ROOT$CONF"; then
	echo "Config $CONF kept as it is."
else
	echo "Config to write ($CONF):"
	sed 's/^/  /' "$TMP/conf"
fi
if [ "$MIGRATE" = 1 ] && [ -e "$ROOT$OLD_CONF" ]; then
	extra=$(GBR_CONF=/dev/null GBR_STATE_DIR="$TMP/none" "$GBR" plan 2>/dev/null | sed -n 's/^[^ ]* \([0-9a-f:.]*\) [0-9a-f:/]* (.*) .*/\1/p' | sort -u | grep -vxF -f <(tr ' ' '\n' <<<"${oldv[0]}") | tr '\n' ' ')
	[ -z "${extra// /}" ] || echo "note: CARDS=auto would also enlarge: $extra(the migrated config keeps the old card list)"
fi

# --- VRAM record and plan (read-only) -------------------------------------------------------------------------
mkdir -p "$TMP/state"
# the record, and the card swaps it noted that no write of the option file has applied yet (SWAP_FILE in the script)
for f in vram replaced; do [ ! -e "$ROOT$STATE/$f" ] || cp "$ROOT$STATE/$f" "$TMP/state/$f"; done
export GBR_CONF=$TMP/conf GBR_STATE_DIR=$TMP/state GBR_ROOT=$ROOT GBR_RUN_DIR=${GBR_RUN_DIR:-/run/$NAME}
# the old option file is moved away below; driver-option reads its groups (which cards had RMForceStaticBar1=0)
# from this copy
if [ -e "$ROOT$OLD_OPTFILE" ]; then cp "$ROOT$OLD_OPTFILE" "$TMP/old-opt"; export GBR_OLD_OPT_FILE=$TMP/old-opt; fi
if [ -e "${GBR_NV_PROC:-/proc/driver/nvidia}/version" ]; then
	# into the scratch state; the driver option is written below, after the question. Its log goes to the scratch dir
	# too: the config's LOG is the live log, which --dry-run and --root must not touch (the lines are printed here).
	# DRIVER_OPTION=off and no CARD entries: this run only records. A write of its own would go to the scratch
	# modprobe dir and remove the note of a card swap it just made, which the write below needs
	{ cat "$TMP/conf"; echo "LOG=$TMP/record.log"; echo "DRIVER_OPTION=off"; echo "CARD=()"; } >"$TMP/conf.record"
	GBR_CONF=$TMP/conf.record GBR_MODPROBE_DIR=$TMP/modprobe-scratch "$GBR" record >"$TMP/record.out" 2>&1 || true
	sed 's/^[^ ]* /  /' "$TMP/record.out"
else
	echo "The NVIDIA driver is not loaded: VRAM unknown (driver never seen this card)."
	echo "It is recorded when the driver loads, and the card is enlarged from the next boot; size= in the config avoids the wait."
fi
echo
echo "Plan (geforce-bar1-resize plan; nothing is written to any GPU now):"
"$GBR" plan 2>&1 | sed 's/^[^ ]* /  /'
echo
adopt=()
[ "$ADOPT" = 0 ] || adopt=(--adopt-driver-line)
"$GBR" driver-option --check "${adopt[@]}" >"$TMP/dopt.out" 2>&1
drc=$?
sed 's/^/  /' "$TMP/dopt.out"
[ "$drc" = 0 ] || die "another modprobe.d file sets NVreg_RegistryDwordsPerDevice (above)"$'\n'"  rerun with --adopt-driver-line to merge it, or remove that line"

# switch on a selected card's path, and the layout module
LAYOUT_NOW=$(sed -n 's/^LAYOUT=\(.*\)/\1/p' "$TMP/conf" | tail -n 1)
SWITCHED=""
while read -r bdf; do
	p=$(readlink -f "/sys/bus/pci/devices/$bdf") || continue
	rest=${p#/sys/devices/*/}
	n=$(tr '/' '\n' <<<"$rest" | grep -c '^[0-9a-f]\{4\}:')
	[ "$n" -le 2 ] || SWITCHED+="$bdf "
done < <("$GBR" plan 2>/dev/null | sed -n 's/^[^ ]* \([0-9a-f]\{4\}:[0-9a-f:.]*\) [0-9a-f:/]* (.*) .*/\1/p' | sort -u)
if [ -n "$SWITCHED" ] && [ "$LAYOUT_NOW" = off ]; then
	echo "note: behind a PCIe switch: ${SWITCHED% }; the plain resize usually fails there."
	echo "  --layout auto turns on the experimental layout module (docs/pcie-switches.md)."
fi
[ "$LAYOUT_NOW" = off ] || [ -z "$SWITCHED" ] || BUILD=1
if [ "$BUILD" = 1 ] && [ -z "$ROOT" ]; then
	[ -d "/lib/modules/$KREL/build" ] ||
		die "layout module: kernel headers for $KREL not found (/lib/modules/$KREL/build)"$'\n'"  Proxmox: apt install proxmox-headers-$KREL; Debian/Ubuntu: apt install linux-headers-$KREL"
	for tool in make cc; do command -v "$tool" >/dev/null || die "layout module: $tool not found (apt install build-essential)"; done
fi

if [ "$DRY" = 0 ] && [ "$YES" = 0 ]; then
	[ -t 0 ] || die "stdin is not a terminal: rerun with --yes to install the above"
	read -r -p "Install? [y/N] " a
	[[ $a == [yY]* ]] || die "nothing installed"
fi

# --- write ------------------------------------------------------------------------------------------------------
put() { # src dest mode
	local dest=$ROOT$2
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
# move an old file into the migration backup
MIG=$ROOT/var/backups/$NAME/$STAMP/migrated-from-rebar-arm
moveold() { # path (below ROOT)
	[ -e "$ROOT$1" ] || [ -L "$ROOT$1" ] || return 0
	run mkdir -p "$MIG$(dirname "$1")"
	run mv "$ROOT$1" "$MIG$1"
	echo "${did}moved $ROOT$1 -> $MIG$1"
}

# layout module first, so a failed build leaves everything as it was
if [ "$BUILD" = 1 ]; then
	echo
	echo "Layout module $MODNAME (kernel/gbr_layout, GPL-2.0-only OR MIT) for kernel $KREL:"
	modver=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$MODSRC/dkms.conf")
	if [ -n "$ROOT" ]; then
		echo "skipped: module build and install (--root); run install.sh --layout-module on the target"
	elif command -v dkms >/dev/null; then
		same=1
		for f in "${MODFILES[@]}"; do cmp -s "$MODSRC/$f" "/usr/src/$DKMSNAME-$modver/$f" || same=0; done
		if [ "$same" = 1 ] && dkms status "$DKMSNAME/$modver" -k "$KREL" 2>/dev/null | grep -q installed; then
			echo "unchanged: dkms $DKMSNAME/$modver is installed for $KREL from the same sources"
		else
			dkms status "$DKMSNAME/$modver" 2>/dev/null | grep -q . && { run dkms remove "$DKMSNAME/$modver" --all || die "dkms remove of the old $DKMSNAME/$modver failed"; }
			run mkdir -p "/usr/src/$DKMSNAME-$modver"
			for f in "${MODFILES[@]}"; do run install -m 0644 "$MODSRC/$f" "/usr/src/$DKMSNAME-$modver/$f"; done
			run dkms add "$DKMSNAME/$modver" || die "dkms add failed"
			run dkms build "$DKMSNAME/$modver" -k "$KREL" || die "dkms build failed (log: /var/lib/dkms/$DKMSNAME/$modver/build/make.log)"
			run dkms install "$DKMSNAME/$modver" -k "$KREL" || die "dkms install failed"
		fi
		echo "DKMS rebuilds the module for each new kernel whose headers are installed."
	else
		mkdir -p "$TMP/layout" && for f in "${MODFILES[@]}"; do cp "$MODSRC/$f" "$TMP/layout/"; done
		run make -C "/lib/modules/$KREL/build" M="$TMP/layout" modules || die "module build failed (output above)"
		if [ -e "/lib/modules/$KREL/updates/$MODNAME.ko" ] &&
			[ "$(modinfo -F srcversion "$TMP/layout/$MODNAME.ko" 2>/dev/null)" = "$(modinfo -F srcversion "/lib/modules/$KREL/updates/$MODNAME.ko" 2>/dev/null)" ]; then
			echo "unchanged /lib/modules/$KREL/updates/$MODNAME.ko (same srcversion)"
		else
			run install -D -m 0644 "$TMP/layout/$MODNAME.ko" "/lib/modules/$KREL/updates/$MODNAME.ko"
			run depmod -a "$KREL"
		fi
		echo "WARNING: dkms is not installed: after every kernel update re-run install.sh --layout-module (or install dkms)."
	fi
	if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q 'SecureBoot enabled'; then
		echo "WARNING: Secure Boot is on: the kernel rejects the module unless it is signed with an enrolled key (DKMS"
		echo "  can sign with its MOK key once enrolled). A rejected module only means the cards stay stock."
	fi
fi

# The new files and the driver option first, then the old install is moved away: a run stopped before
# the moves leaves the old install in place next to the new files; one stopped after them leaves the new config,
# mapped from the old one, and the in-progress marker below.
echo
cp "$SRC/systemd/$UNIT" "$TMP/unit"
put "$GBR" "$SCRIPT" 0755
put "$TMP/unit" "$UNITFILE" 0644
put "$SRC/systemd/$RUNIT" "$RUNITFILE" 0644
put "$SRC/udev/90-$NAME.rules" "$RULE" 0644
put "$TMP/conf" "$CONF" 0644
if [ -e "$TMP/state/vram" ]; then put "$TMP/state/vram" "$STATE/vram" 0644; fi
if [ -e "$TMP/state/replaced" ]; then put "$TMP/state/replaced" "$STATE/replaced" 0644; fi

# the driver option file, from the installed config (and the old option file's keys, read from its copy)
echo
if [ "$DRY" = 1 ]; then
	echo "Driver option file that would be written:"
	GBR_STATE_DIR=$TMP/state "$GBR" driver-option --print | sed 's/^/  /'
else
	GBR_CONF=$ROOT$CONF GBR_STATE_DIR=$ROOT$STATE "$GBR" driver-option --write "${adopt[@]}" || die "driver-option --write failed (above)"
fi

echo
# migration steps 4-6 (docs/migration.md): disable the old unit, keep its drop-ins, move the old files away, remove the
# old module; the new unit is enabled only afterwards, so no boot ever has both. $STATE/migrating, written before the
# disable and removed with the last step, tells a rerun to finish the migration and whether the old unit was enabled.
if [ "$MIGRATE" = 1 ]; then
	echo "Migrating from 3080-20gb-rebar (old files go to $MIG):"
	if [ "$DRY" = 0 ]; then
		mkdir -p "$ROOT$STATE" "$MIG"
		printf '# Written by install.sh on %s: migration from 3080-20gb-rebar in progress (old files in %s).\nrebar-arm.service was %s.\n' \
			"$STAMP" "${MIG#"$ROOT"}" "$([ "$OLD_ENABLED" = 1 ] && echo enabled || echo "not enabled")" >"$ROOT$STATE/migrating"
		{
			echo "Moved here by install.sh (geforce-bar1-resize) on $STAMP when it replaced 3080-20gb-rebar."
			echo "To go back: uninstall geforce-bar1-resize (./uninstall.sh), then copy these files back to the same"
			echo "paths below /, run systemctl daemon-reload and systemctl enable $OLD_UNIT."
			echo "rebar-arm.service was $([ "$OLD_ENABLED" = 1 ] && echo enabled || echo not enabled)."
		} >"$MIG/RESTORE.txt"
	fi
	if [ -n "$ROOT" ]; then echo "skipped: systemctl disable $OLD_UNIT (--root; the enable link is moved)"
	else run systemctl disable "$OLD_UNIT" 2>/dev/null || true; fi
	if [ -d "$ROOT$OLD_UNITFILE.d" ]; then
		for f in "$ROOT$OLD_UNITFILE.d"/*.conf; do
			[ -e "$f" ] || continue
			{ echo "# Copied by install.sh from $OLD_UNITFILE.d/${f##*/} (3080-20gb-rebar); check it still applies."; cat "$f"; } >"$TMP/dropin"
			put "$TMP/dropin" "$UNITFILE.d/${f##*/}" 0644
		done
	fi
	for f in "${OLD_FILES[@]}"; do moveold "$f"; done
	for v in $OLD_DKMS; do run dkms remove "rebar-layout/$v" --all || echo "dkms remove rebar-layout/$v failed"; done
	krels=()
	for f in "${OLD_MODS[@]}"; do
		moveold "$f"
		[[ $f != /lib/modules/* ]] || { f=${f#/lib/modules/}; krels+=("${f%%/*}"); }
	done
	for k in "${krels[@]}"; do if [ -n "$ROOT" ]; then echo "skipped: depmod -a $k (--root)"; else run depmod -a "$k"; fi; done
fi

if [ -n "$ROOT" ]; then echo "skipped: systemctl daemon-reload, udevadm control --reload (--root)"
else run systemctl daemon-reload; run udevadm control --reload 2>/dev/null || true; fi
if [ "$ENABLE" = 1 ] || [ "$OLD_ENABLED" = 1 ]; then
	[ "$ENABLE" = 1 ] || echo "Enabling $UNIT: the migrated $OLD_UNIT was enabled."
	if [ -n "$ROOT" ]; then
		run mkdir -p "$ROOT/etc/systemd/system/sysinit.target.wants"
		[ -L "$ROOT/etc/systemd/system/sysinit.target.wants/$UNIT" ] || run ln -s "$UNITFILE" "$ROOT/etc/systemd/system/sysinit.target.wants/$UNIT"
	else
		run systemctl enable "$UNIT"
	fi
fi
# the last step: the done marker replaces the in-progress one
if { [ "$MIGRATE" = 1 ] || [ "$RESUME" = 1 ]; } && [ "$DRY" = 0 ]; then
	{
		echo "# Written by install.sh: migrated from 3080-20gb-rebar on $STAMP; old files in ${MIG#"$ROOT"}"
		[ "$RESUME" = 0 ] || echo "# finished a migration an earlier run had started"
		printf '%s\n' "${OLD_FILES[@]}" "${OLD_MODS[@]}"
	} >"$TMP/migrated"
	put "$TMP/migrated" "$STATE/migrated" 0644
	rm -f "$ROOT$STATE/migrating"
fi
if [ -n "$ROOT" ]; then
	state=disabled
	[ -L "$ROOT/etc/systemd/system/sysinit.target.wants/$UNIT" ] && state=enabled
else
	state=$(systemctl is-enabled "$UNIT" 2>/dev/null) || true
fi
echo "Unit state now: ${state:-unknown}$([ "$DRY" = 1 ] && echo " (dry-run: nothing was changed)")"
[ "$state" = enabled ] || echo "To enlarge at every boot: sudo systemctl enable $UNIT"
[ ! -d "$ROOT$UNITFILE.d" ] || echo "note: drop-in directory $ROOT$UNITFILE.d exists and overrides parts of the unit"

echo
if [ ${#RESTORE[@]} -gt 0 ]; then
	echo "Replaced files are kept in $BACKUP. To restore them:"
	printf '  %s\n' "${RESTORE[@]}"
fi
echo "Nothing was written to any GPU. The service acts at the next boot (if enabled), before the driver binds."
echo "After reboot check: journalctl -b -u $UNIT; lspci -vv -s <BDF> | grep 'Region 1'"
