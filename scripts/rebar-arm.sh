#!/bin/bash
# Arm the GA102 frame-buffer size override (config 0x610) and resize BAR1, no flash.
#
# Usage: rebar-arm.sh [--repair] [BDF ...]
#   BDFs come from the arguments, else from REBAR_BDFS in the config file
#   (/etc/rebar-arm.conf, or the path in $REBAR_ARM_CONF).
#   The BAR1 size is 64 MiB << REBAR_N (config, default 9 = 32 GiB). rebar-check.sh suggests REBAR_N.
#
# Run before the GPU driver binds (the systemd unit orders it before systemd-modules-load).
# Idempotent: 0x610 is written only if bits 11:7 differ from the target, and BAR1 is resized only if its
# current length (from the device's sysfs `resource` file) differs from 64 MiB << REBAR_N.
# Never fatal: a failure is logged and the card stays at whatever size it has. If the resize fails (the kernel
# could not fit BAR1), 0x610 is restored to its value before the run, so the capability matches the real BAR1.
# Log: every line goes to stdout (the journal under systemd) first; appending to REBAR_LOG is best-effort,
# because at early boot the root file system can still be read-only. At boot, `journalctl -u rebar-arm` is
# the authoritative log.
#
# --repair: for cards that are already bound and may already have a wide BAR1. Re-arms the
# field only after a reset (FLR / driver recovery) cleared it, and only if BAR1 already has the
# target size. Never resizes, never unbinds.
set -u

CONF=${REBAR_ARM_CONF:-/etc/rebar-arm.conf}
REBAR_BDFS=""             # space-separated, e.g. "0000:01:00.0 0000:02:00.0"
REBAR_IDS="10de:2206"     # vendor:device pairs allowed to be touched
REBAR_N=9                 # 64 MiB << 9 = 32 GiB; the only value verified (RTX 3080 20GB)
REBAR_LOG=/var/log/rebar-arm.log
# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

log() {
	local line
	line="$(date -Is) $*"
	printf '%s\n' "$line"
	{ printf '%s\n' "$line" >>"$REBAR_LOG"; } 2>/dev/null || true
}

REPAIR=0
if [ "${1:-}" = "--repair" ]; then REPAIR=1; shift; fi
[ $# -gt 0 ] && REBAR_BDFS="$*"
if [ -z "$REBAR_BDFS" ]; then
	log "no devices given (pass BDFs or set REBAR_BDFS in $CONF), nothing to do"
	exit 0
fi
case $REBAR_N in
	[0-9] | 1[0-3]) ;;
	*) log "REBAR_N=$REBAR_N out of range 0..13, nothing done"; exit 0 ;;
esac

MASK=$((0x0f80))                         # bits 11:7 only; bit 12 (GEN3) and bit 0 (GEN2) stay as shipped
FIELD=$((0x800 | REBAR_N << 7))          # FB_SIZE_OVERRIDE_EN (bit 11) + VAL n (bits 10:7)
SET=$(printf '%08x:%08x' "$FIELD" "$MASK")
CAP_BIT=$((REBAR_N + 10))                # 0xbbc bit for 64 MiB << n (bit 10 = 64 MiB)
IDX=$((REBAR_N + 6))                     # encoded ReBAR size for resource1_resize (6 = 64 MiB)
SIZE="$((64 << REBAR_N)) MiB"
BYTES=$((64 << (REBAR_N + 20)))

armed() { [ $((0x$(setpci -s "$1" 0x610.L) & MASK)) = "$FIELD" ]; }
cap_wide() { [ $(((0x$(setpci -s "$1" 0xbbc.L) >> CAP_BIT) & 1)) = 1 ]; }
bar1_len() { local start end; read -r start end _ < <(sed -n 2p "$1/resource" 2>/dev/null) && echo $((end - start + 1)); }

for bdf in $REBAR_BDFS; do
	case $bdf in ????:*) ;; *) bdf=0000:$bdf ;; esac
	dev=/sys/bus/pci/devices/$bdf
	if [ ! -e "$dev" ]; then log "$bdf absent, skip"; continue; fi
	id="$(cat "$dev/vendor"):$(cat "$dev/device")"
	id=${id//0x/}
	case " $REBAR_IDS " in
		*" $id "*) ;;
		*) log "$bdf is $id, not in REBAR_IDS ($REBAR_IDS), skip"; continue ;;
	esac
	if [ -e "$dev/driver" ]; then
		if [ "$REPAIR" = 1 ] && ! cap_wide "$bdf"; then
			len=$(bar1_len "$dev")
			if [ "$len" != "$BYTES" ]; then
				log "$bdf bound with BAR1 $((${len:-0} >> 20)) MiB, not the target; --repair skips (would leave the driver and the hardware out of step)"
			elif setpci -s "$bdf" "0x610.L=$SET" && cap_wide "$bdf"; then
				log "$bdf bound; re-armed after reset, 0xbbc now $(setpci -s "$bdf" 0xbbc.L)"
			else
				log "$bdf bound; re-arm after reset failed (0x610=$(setpci -s "$bdf" 0x610.L 2>/dev/null), 0xbbc=$(setpci -s "$bdf" 0xbbc.L 2>/dev/null))"
			fi
		else
			log "$bdf already bound to $(basename "$(readlink -f "$dev/driver")"), skip"
		fi
		continue
	fi
	if [ "$REPAIR" = 1 ]; then log "$bdf not bound; --repair only touches bound cards, skip"; continue; fi

	prev=$(setpci -s "$bdf" 0x610.L 2>/dev/null) || { log "$bdf 0x610 unreadable"; continue; }
	restore=$((0x$prev & MASK))          # bits 11:7 before this run; stock on the verified card: 0 (EN=0 VAL=0)
	[ "$restore" = "$FIELD" ] && restore=0 # already armed by an earlier run: back off to stock
	if ! armed "$bdf"; then
		setpci -s "$bdf" "0x610.L=$SET" || { log "$bdf 0x610 write failed"; continue; }
	fi
	if ! armed "$bdf"; then
		log "$bdf 0x610 did not latch (reads $(setpci -s "$bdf" 0x610.L))"; continue
	fi
	if ! cap_wide "$bdf"; then
		log "$bdf capability did not widen (0xbbc=$(setpci -s "$bdf" 0xbbc.L)), skip resize"; continue
	fi
	if [ "$(bar1_len "$dev")" = "$BYTES" ]; then
		log "$bdf already armed and resized ($SIZE), skip"; continue
	fi
	mask=$(cat "$dev/resource1_resize" 2>/dev/null) || mask=0
	if [ $(((0x$mask >> IDX) & 1)) != 1 ]; then
		log "$bdf resize mask not widened ($mask), skip resize"; continue
	fi
	if echo "$IDX" >"$dev/resource1_resize" 2>/dev/null; then
		log "$bdf armed and resized to $SIZE"
	else
		len=$(bar1_len "$dev")
		if [ "$len" = "$BYTES" ]; then
			log "$bdf armed; resize write failed but BAR1 is $SIZE, left armed"
		elif setpci -s "$bdf" "0x610.L=$(printf '%08x:%08x' "$restore" "$MASK")" &&
			[ $((0x$(setpci -s "$bdf" 0x610.L) & MASK)) = "$restore" ] && ! cap_wide "$bdf"; then
			log "$bdf resize failed (kernel could not fit BAR1, see dmesg); disarmed, left at stock $((${len:-0} >> 20)) MiB"
		else
			log "$bdf resize failed and disarm failed (0x610=$(setpci -s "$bdf" 0x610.L 2>/dev/null), 0xbbc=$(setpci -s "$bdf" 0xbbc.L 2>/dev/null))"
		fi
	fi
done
exit 0
