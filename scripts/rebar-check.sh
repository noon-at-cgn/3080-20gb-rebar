#!/bin/bash
# Read-only compatibility check for the GA102 BAR1 size override. Writes nothing to any device.
#
# Usage: rebar-check.sh [--vram SIZE] [BDF ...]
#   BDF ...      cards to check; default: every NVIDIA display-class device
#   --vram SIZE  the card's VRAM, e.g. 20G or 20480M (plain number = GiB). Used to suggest REBAR_N.
#                Without it, you are asked when stdin is a terminal.
# Needs root: config space above 0x40 is only readable by root.
#
# Exit status: 0 preconditions hold on every card checked, 1 at least one card fails, 2 usage error.
set -u

VERIFIED_IDS="10de:2206"
VERIFIED_SUBSYS="10de:146d"
VERIFIED_VBIOS="94.02.27.00.14"

die() { echo "rebar-check: $*" >&2; exit 2; }
[ "$(id -u)" = 0 ] || die "run as root (setpci cannot read extended config space otherwise)"
command -v setpci >/dev/null || die "setpci not found (install pciutils)"

VRAM=""
BDFS=()
while [ $# -gt 0 ]; do
	case $1 in
		--vram) [ $# -ge 2 ] || die "--vram needs a value"; VRAM=$2; shift 2 ;;
		-h | --help) sed -n '2,10p' "$0"; exit 0 ;;
		*) BDFS+=("$1"); shift ;;
	esac
done
if [ ${#BDFS[@]} = 0 ]; then
	for dev in /sys/bus/pci/devices/*; do
		[ "$(cat "$dev/vendor")" = 0x10de ] && [[ $(cat "$dev/class") == 0x03* ]] && BDFS+=("${dev##*/}")
	done
fi
[ ${#BDFS[@]} -gt 0 ] || die "no NVIDIA display device found"

# VRAM size -> MiB
vram_mib() {
	local v=${1^^}
	case $v in
		*G | *GB | *GIB) v=${v%%G*}; [[ $v =~ ^[0-9]+$ ]] && echo $((v * 1024)) ;;
		*M | *MB | *MIB) v=${v%%M*}; [[ $v =~ ^[0-9]+$ ]] && echo "$v" ;;
		*) [[ $v =~ ^[0-9]+$ ]] && echo $((v * 1024)) ;;
	esac
}
# smallest n with 64 MiB << n >= VRAM, i.e. n = ceil(log2(VRAM / 64 MiB))
suggest_n() {
	local mib=$1 n=0
	while [ $((64 << n)) -lt "$mib" ]; do n=$((n + 1)); done
	echo "$n"
}
bit() { echo $(((0x$1 >> $2) & 1)); }

FAIL=0
for bdf in "${BDFS[@]}"; do
	case $bdf in ????:*) ;; *) bdf=0000:$bdf ;; esac
	dev=/sys/bus/pci/devices/$bdf
	echo "== $bdf"
	if [ ! -e "$dev" ]; then echo "  FAIL device not present"; FAIL=1; continue; fi
	bad=0 untested=0
	ok() { echo "  ok    $*"; }
	no() { echo "  FAIL  $*"; bad=1; }
	unv() { echo "  note  $*"; untested=1; }

	id="$(cat "$dev/vendor"):$(cat "$dev/device")"; id=${id//0x/}
	sub="$(cat "$dev/subsystem_vendor"):$(cat "$dev/subsystem_device")"; sub=${sub//0x/}
	drv=$( [ -e "$dev/driver" ] && basename "$(readlink -f "$dev/driver")" || echo none)
	echo "  ids $id subsystem $sub driver $drv boot_vga $(cat "$dev/boot_vga" 2>/dev/null || echo n/a)"
	case " $VERIFIED_IDS " in *" $id "*) ok "device id $id is the verified GA102 id" ;;
		*) unv "device id $id not verified (verified: $VERIFIED_IDS); the arm script skips it unless added to REBAR_IDS" ;; esac
	[ "$sub" = "$VERIFIED_SUBSYS" ] || unv "subsystem $sub differs from the verified $VERIFIED_SUBSYS"

	vbios=unknown
	info=/proc/driver/nvidia/gpus/$bdf/information
	if [ -r "$info" ]; then
		vbios=$(awk -F':[ \t]*' '/^Video BIOS/ {print $2}' "$info")
	elif command -v nvidia-smi >/dev/null && [ "$drv" = nvidia ]; then
		vbios=$(nvidia-smi -i "$bdf" --query-gpu=vbios_version --format=csv,noheader 2>/dev/null || echo unknown)
	fi
	echo "  vBIOS $vbios"
	if [ "$vbios" = "$VERIFIED_VBIOS" ]; then ok "vBIOS is the verified $VERIFIED_VBIOS"
	elif [ "$vbios" = unknown ]; then unv "vBIOS not readable without the nvidia driver bound"
	else unv "vBIOS $vbios not verified (verified: $VERIFIED_VBIOS)"; fi

	vsec=$(setpci -s "$bdf" 0x600.L 2>/dev/null) || vsec=""
	vhdr=$(setpci -s "$bdf" 0x604.L 2>/dev/null) || vhdr=""
	r60c=$(setpci -s "$bdf" 0x60c.L 2>/dev/null) || r60c=""
	r610=$(setpci -s "$bdf" 0x610.L 2>/dev/null) || r610=""
	rbb0=$(setpci -s "$bdf" 0xbb0.L 2>/dev/null) || rbb0=""
	rbbc=$(setpci -s "$bdf" 0xbbc.L 2>/dev/null) || rbbc=""
	rbc0=$(setpci -s "$bdf" 0xbc0.L 2>/dev/null) || rbc0=""
	echo "  0x600 ${vsec:-?} 0x604 ${vhdr:-?} 0x60c ${r60c:-?} 0x610 ${r610:-?}"
	echo "  0xbb0 ${rbb0:-?} 0xbbc ${rbbc:-?} 0xbc0 ${rbc0:-?} resource1_resize $(cat "$dev/resource1_resize" 2>/dev/null || echo absent)"

	if [ -n "$vsec" ] && [ $((0x$vsec & 0xffff)) = $((0x000b)) ] && [ -n "$vhdr" ] && [ $((0x$vhdr & 0xffff)) = 1 ]; then
		ok "vendor-specific capability (ID 0001) at 0x600"
	else no "no NVIDIA vendor-specific capability at 0x600; the 0x60c/0x610 layout does not apply"; fi
	if [ -n "$r60c" ] && [ "$(bit "$r60c" 11)" = 1 ]; then ok "0x60c bit 11 FB_SIZE_OVERRIDE = SUPPORTED"
	else no "0x60c bit 11 FB_SIZE_OVERRIDE not set"; fi
	if [ -n "$r610" ]; then
		if [ "$(bit "$r610" 11)" = 1 ]; then
			ok "0x610 override already armed, VAL $(((0x$r610 >> 7) & 0xf)) ($((64 << ((0x$r610 >> 7) & 0xf))) MiB)"
		else ok "0x610 override disarmed (stock on the verified card: 00001001)"; fi
	else no "0x610 unreadable"; fi
	if [ -n "$rbb0" ] && [ $((0x$rbb0 & 0xffff)) = $((0x0015)) ]; then ok "Resizable BAR capability at 0xbb0"
	else no "no Resizable BAR capability at 0xbb0; 0xbbc/0xbc0 do not describe BAR1 here"; fi
	if [ -n "$rbc0" ] && [ $((0x$rbc0 & 7)) = 1 ]; then ok "0xbc0 entry is BAR1, current size index $(((0x$rbc0 >> 8) & 0x1f))"
	else no "0xbc0 entry is not BAR1"; fi
	if [ -e "$dev/resource1_resize" ]; then ok "kernel exposes resource1_resize"
	else no "kernel has no resource1_resize (needs sysfs BAR resize support)"; fi

	if [ "$bad" = 1 ]; then echo "  VERDICT preconditions do NOT hold"; FAIL=1
	elif [ "$untested" = 1 ]; then echo "  VERDICT preconditions hold, but this is not the verified configuration (untested)"
	else echo "  VERDICT preconditions hold on the verified configuration"; fi
	if [ "$drv" = nvidia ] && command -v nvidia-smi >/dev/null; then
		echo "  driver reports VRAM $(nvidia-smi -i "$bdf" --query-gpu=memory.total --format=csv,noheader 2>/dev/null)"
	fi
done

if [ -z "$VRAM" ] && [ -t 0 ]; then
	read -r -p "VRAM size of the card(s) to arm (e.g. 20G, 10240M; empty to skip): " VRAM
fi
if [ -n "$VRAM" ]; then
	mib=$(vram_mib "$VRAM")
	[ -n "$mib" ] && [ "$mib" -gt 0 ] || die "cannot parse VRAM size '$VRAM'"
	n=$(suggest_n "$mib")
	echo "== REBAR_N for $mib MiB VRAM: $n (BAR1 $((64 << n)) MiB, 0x610 armed = $(printf '%08x' $((0x1001 | 0x800 | n << 7))))"
	echo "   Verified only for n = 9 on the RTX 3080 20GB; any other card or n is PREDICTED, not tested."
	[ "$n" -le 13 ] || echo "   n > 13 exceeds the ReBAR maximum (512 GiB); not usable."
fi
exit $FAIL
