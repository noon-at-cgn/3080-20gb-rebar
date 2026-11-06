#!/bin/bash
# shellcheck disable=SC2317 # the helpers below are called from the sourced cases-*.sh files
# SPDX-License-Identifier: MIT
# Stand-in tests of geforce-bar1-resize (scripts/geforce-bar1-resize, install.sh, uninstall.sh): card layouts,
# addresses, structural checks, sizes, routes, failure modes, the VRAM record, the driver option file, the layout
# module's handling and the migration from 3080-20gb-rebar, against a fake /sys tree and a fake setpci. No real GPU,
# config space or sysfs file is touched and no kernel module is loaded (modprobe/modinfo/rmmod/dmesg stand in for the
# gbr_layout module and the kernel log). Nothing is written outside $WORK.
#
# Usage, from the repository root, as a normal user:  tests/run.sh [CASE-PREFIX...]
#   e.g. tests/run.sh 0 1   (cases 01-19 and 100-120)
# Needs bash, coreutils, grep, sed, awk, find, cmp, cc (a small LD_PRELOAD library is built), ps and setsid; git and
# network access for the geforce-dynbar1-p2p (formerly 3080-20g-p2p) contract cases (skipped with a note otherwise).
# Environment: WORK (scratch and logs; default a new mktemp -d directory, removed when every case passes),
# P2P_TREE (an existing geforce-dynbar1-p2p checkout instead of the clone).
# Output: one PASS/FAIL/SKIP line per case and a results table. Exit status: 0 when no case failed, else the number
# of failed cases (at most 125).
#
# How the scripts see the fake tree: they run as copies in $WORK/src made with sed 's|/sys/|$FAKE/sys/|g' and
# 's|/proc/iomem|$FAKE/proc/iomem|g', the only changes (checked by reversing them). $WORK/bin comes first in PATH:
# setpci is the fake card, `id -u` prints 0, lspci/systemctl/dkms are stubs, nvidia-smi is a fake reading
# $FAKE/smi, modprobe/modinfo/rmmod/dmesg stand in for the module and the kernel log, and `modinfo -F version nvidia`
# prints $FAKE/nvidia-version (the nvidia module the next load would use; not found without that file).
# The script runs with LD_PRELOAD=$WORK/bin/standin-open.so for kernel behaviours a plain file cannot give: a write
# to resource1_resize fails with ENOSPC when resource1_resize.enospc exists next to it and with ENOENT when
# resource1_resize.enoent exists, writes to drivers_probe append, and reading a `resource` file first applies
# pending resizes (setpci --settle).
# shellcheck disable=SC2329 # check() helpers are called indirectly
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PUB=$(cd "$HERE/.." && pwd) || exit 2
ONLY=("$@")
REAL_ID=$(type -P id)
[ "$("$REAL_ID" -u)" != 0 ] || { echo "run as a normal user: the resize failure mode relies on file permissions" >&2; exit 2; }
for t in cc ps setsid sed awk find; do
	command -v "$t" >/dev/null || { echo "tests/run.sh needs $t" >&2; exit 2; }
done
OWN_WORK=0
if [ -z "${WORK:-}" ]; then WORK=$(mktemp -d "${TMPDIR:-/tmp}/gbr-tests.XXXXXX") && OWN_WORK=1 || exit 2; fi
[[ $WORK != *[\|\&\\]* ]] || { echo "WORK must not contain | & or \\" >&2; exit 2; }
if [ "$OWN_WORK" = 0 ] && [ -e "$WORK" ]; then
	[ -e "$WORK/.standins" ] || [ -z "$(ls -A "$WORK")" ] || { echo "$WORK exists and is not an earlier run; not wiping it" >&2; exit 2; }
	rm -rf "${WORK:?}"/* "$WORK/.standins"
fi
mkdir -p "$WORK/src/scripts" "$WORK/bin" "$WORK/cases" && touch "$WORK/.standins"
WORK=$(cd "$WORK" && pwd -P)
FAKE=$WORK/fake SRC=$WORK/src BIN=$WORK/bin

# --- copies with only /sys/ and /proc/iomem substituted -------------------------------------------------------------
subst() { sed -e "s|/sys/|$FAKE/sys/|g" -e "s|/proc/iomem|$FAKE/proc/iomem|g" "$1"; }
unsubst() { sed -e "s|$FAKE/sys/|/sys/|g" -e "s|$FAKE/proc/iomem|/proc/iomem|g" "$1"; }
for f in scripts/geforce-bar1-resize install.sh uninstall.sh; do
	subst "$PUB/$f" >"$SRC/$f" && chmod 755 "$SRC/$f"
	unsubst "$SRC/$f" | cmp -s - "$PUB/$f" || { echo "substitution is not reversible in $f" >&2; exit 2; }
	echo "copy $f: $(grep -c "$FAKE/" "$SRC/$f") line(s) substituted, nothing else changed"
done
for d in systemd udev config kernel; do [ ! -d "$PUB/$d" ] || cp -r "$PUB/$d" "$SRC/"; done

# --- stand-ins ---------------------------------------------------------------------------------------------------
cat >"$WORK/standin-open.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *fix(const char *path, int *flags)
{
	static char m[4096];
	size_t n = strlen(path);

	if ((*flags & O_ACCMODE) == O_RDONLY) {
		if (n >= 9 && !strcmp(path + n - 9, "/resource") && !getenv("STANDIN_SETTLING")) {
			setenv("STANDIN_SETTLING", "1", 1);
			if (system("setpci --settle >/dev/null 2>&1"))
				;
			unsetenv("STANDIN_SETTLING");
		}
		return path;
	}
	if (n >= 13 && !strcmp(path + n - 13, "drivers_probe")) {
		*flags = (*flags & ~O_TRUNC) | O_APPEND;
		return path;
	}
	if (n >= 16 && !strcmp(path + n - 16, "resource1_resize")) {
		if (snprintf(m, sizeof(m), "%s.enoent", path) < (int)sizeof(m) && !access(m, F_OK))
			return NULL;
		if (snprintf(m, sizeof(m), "%s.enospc", path) < (int)sizeof(m) && !access(m, F_OK))
			return "/dev/full";
	}
	return path;
}

#define WRAP(name)                                                              \
	int name(const char *path, int flags, ...)                              \
	{                                                                       \
		static int (*real)(const char *, int, ...);                     \
		int mode = 0;                                                   \
		va_list ap;                                                     \
		va_start(ap, flags);                                            \
		if (flags & O_CREAT)                                            \
			mode = va_arg(ap, int);                                 \
		va_end(ap);                                                     \
		if (!real)                                                      \
			real = (int (*)(const char *, int, ...))dlsym(RTLD_NEXT, #name); \
		path = fix(path, &flags);                                       \
		if (!path) {                                                    \
			errno = ENOENT;                                         \
			return -1;                                              \
		}                                                               \
		return real(path, flags, mode);                                 \
	}
#define WRAPAT(name)                                                            \
	int name(int dfd, const char *path, int flags, ...)                     \
	{                                                                       \
		static int (*real)(int, const char *, int, ...);                \
		int mode = 0;                                                   \
		va_list ap;                                                     \
		va_start(ap, flags);                                            \
		if (flags & O_CREAT)                                            \
			mode = va_arg(ap, int);                                 \
		va_end(ap);                                                     \
		if (!real)                                                      \
			real = (int (*)(int, const char *, int, ...))dlsym(RTLD_NEXT, #name); \
		path = fix(path, &flags);                                       \
		if (!path) {                                                    \
			errno = ENOENT;                                         \
			return -1;                                              \
		}                                                               \
		return real(dfd, path, flags, mode);                            \
	}
WRAP(open)
WRAP(open64)
WRAPAT(openat)
WRAPAT(openat64)
#define WRAPF(name)                                                             \
	FILE *name(const char *path, const char *mode)                          \
	{                                                                       \
		static FILE *(*real)(const char *, const char *);               \
		int flags = O_RDONLY;                                           \
		if (!real)                                                      \
			real = (FILE * (*)(const char *, const char *))dlsym(RTLD_NEXT, #name); \
		if (mode[0] == 'r' && mode[1] != '+')                           \
			fix(path, &flags);                                      \
		return real(path, mode);                                        \
	}
WRAPF(fopen)
WRAPF(fopen64)
EOF
cc -shared -fPIC -O1 -U_FORTIFY_SOURCE -o "$BIN/standin-open.so" "$WORK/standin-open.c" -ldl ||
	{ echo "cannot build the open() stand-in (needs cc)" >&2; exit 2; }

# gbr_layout module stand-in. Mode from $REBAR_FAKE/layout-mode: ok (default; every target's BAR1 becomes
# 1 MiB << size), nospace, rollback-failed, nolog-killed, nolog-reject, nolog-notrecoverable; or per call, the first
# line of $REBAR_FAKE/layout-modes (removed as it is used). dry_run=1 only logs.
# Records its arguments in modprobe.calls and every function's driver_override at load time in overrides-at-modprobe.
# `modprobe -c` prints $REBAR_FAKE/modprobe-c.
cat >"$BIN/modprobe" <<'EOF'
#!/bin/bash
set -u
F=$REBAR_FAKE
if [ "${1:-}" = -c ]; then cat "$F/modprobe-c" 2>/dev/null; exit 0; fi
[ "${1:-}" = gbr_layout ] || { echo "modprobe stand-in: only gbr_layout" >&2; exit 1; }
shift
echo "$*" >>"$F/modprobe.calls"
targets="" size="" dry=0
for a; do case $a in targets=*) targets=${a#*=} ;; size=*) size=${a#*=} ;; dry_run=*) dry=${a#*=} ;; esac; done
while IFS= read -r o; do d=${o%/driver_override}; echo "${d##*/} $(cat "$o")"; done < <(find "$F/sys/devices" -name driver_override | sort) >"$F/overrides-at-modprobe"
klog() { printf '[%5d.000001] gbr_layout: %s\n' "$(cat "$F/dmesg" 2>/dev/null | wc -l)" "$*" >>"$F/dmesg"; }
mode=$(cat "$F/layout-mode" 2>/dev/null || echo ok)
if [ -s "$F/layout-modes" ]; then mode=$(head -n 1 "$F/layout-modes"); sed -i 1d "$F/layout-modes"; fi
[[ $mode == nolog-* ]] || klog "start targets=$(tr , '\n' <<<"$targets" | grep -c .) bar=1 size=$size dry_run=$dry"
[ ! -e "$F/sigterm-in-modprobe" ] || kill -TERM "$(cat "$F/arm.pid")"
if [ "$dry" = 1 ]; then
	klog "root 0000:00:03.0 window 0x1000000000 align 0x800000000 predicted 0x380800000000"
	klog "root 0000:00:03.0 result dry-run"; klog "done rc=0"
	mkdir -p "$F/sys/module/gbr_layout"; exit 0
fi
case $mode in
	ok)
		for t in ${targets//,/ }; do
			sys=$(<"$F/cfg/$t/sysdir") ctl=$(<"$F/cfg/$t/ctlreg")
			read -r s _ < <(sed -n 2p "$sys/resource")
			printf -v line '0x%016x 0x%016x 0x%016x' "$s" $((s + (1 << (size + 20)) - 1)) 0x14220c
			sed -i "2s/.*/$line/" "$sys/resource"
			printf '%08x\n' $(((0x$(<"$F/cfg/$t/$ctl") & ~0x3f00) | size << 8)) >"$F/cfg/$t/$ctl"
		done
		klog "root 0000:00:03.0 result ok"; klog "done rc=0"
		mkdir -p "$F/sys/module/gbr_layout"; exit 0 ;;
	nospace)
		klog "root 0000:00:03.0 refuse 0000:00:03.0: window 0x1000000000 align 0x800000000 fits no host bridge window"
		klog "root 0000:00:03.0 result nospace"; klog "done rc=-28"
		echo "modprobe: ERROR: could not insert 'gbr_layout': No space left on device" >&2; exit 1 ;;
	rollback-failed)
		klog "root 0000:00:03.0 result rollback-failed"; klog "done rc=-131"
		echo "modprobe: ERROR: could not insert 'gbr_layout': State not recoverable" >&2; exit 1 ;;
	nolog-killed)
		kill -KILL $$ ;;
	nolog-reject)
		echo "modprobe: ERROR: could not insert 'gbr_layout': Key was rejected by service" >&2; exit 1 ;;
	nolog-notrecoverable)
		echo "modprobe: ERROR: could not insert 'gbr_layout': State not recoverable" >&2; exit 1 ;;
esac
EOF
cat >"$BIN/modinfo" <<'EOF'
#!/bin/sh
if [ "$*" = "-F version nvidia" ]; then
	[ -e "$REBAR_FAKE/nvidia-version" ] && exec cat "$REBAR_FAKE/nvidia-version"
	echo "modinfo: ERROR: Module nvidia not found." >&2; exit 1
fi
[ "$1" = gbr_layout ] && [ ! -e "$REBAR_FAKE/no-module" ] || { echo "modinfo: ERROR: Module $1 not found." >&2; exit 1; }
echo "filename:       /lib/modules/stand-in/updates/dkms/gbr_layout.ko"
EOF
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/bin/sh\necho "$*" >>"$REBAR_FAKE/rmmod.calls"\nrmdir "$REBAR_FAKE/sys/module/$1"\n' >"$BIN/rmmod"
# shellcheck disable=SC2016
printf '#!/bin/sh\ncat "$REBAR_FAKE/dmesg" 2>/dev/null\n' >"$BIN/dmesg"
printf '#!/bin/sh\necho "depmod $*" >>"%s/depmod.calls"\n' "$WORK" >"$BIN/depmod"
# nvidia-smi: the lines in $REBAR_FAKE/smi for --query-gpu=pci.bus_id,memory.total,driver_version; fails without them.
# Every call is appended to $REBAR_FAKE/smi.calls.
cat >"$BIN/nvidia-smi" <<'EOF'
#!/bin/sh
echo "$*" >>"$REBAR_FAKE/smi.calls"
case "$*" in
	*pci.bus_id,memory.total,driver_version*) [ -e "$REBAR_FAKE/smi" ] && exec cat "$REBAR_FAKE/smi" ;;
	*driver_version*) [ -e "$REBAR_FAKE/smi" ] && { sed -n '1s/.*, //p' "$REBAR_FAKE/smi"; exit 0; } ;;
esac
echo "nvidia-smi stand-in: no GPU" >&2
exit 1
EOF

cat >"$BIN/setpci" <<'EOF'
#!/bin/bash
# Fake setpci: -s BDF REG[.B|.W|.L][=VAL[:MASK]]. Registers live in $REBAR_FAKE/cfg/<BDF>/<reg> (8 hex digits; an
# absent register reads 0). The card's BAR1 ReBAR capability/control registers are named in cfg/<BDF>/capreg and
# ctlreg. On a card with cfg/<BDF>/xve, writing 0x610 with bit 11 and VAL in bits 10:7 widens the capability to
# 64 MiB..64 MiB<<VAL (and the sysfs mask); clearing bit 11 restores the stock capability (cfg/<BDF>/stockcap).
# Kernel behaviour (applied before every call, and by --settle): a size index written to resource1_resize resizes
# BAR1, updates the control register's size and restores the mask.
# Failure modes (files in cfg/<BDF>/): fail-write-<reg>, latch-<reg> (how many more writes latch), no-resize,
# no-widen (cap and mask unchanged), no-mask (only the mask), narrow (the cap loses its smallest size),
# kill-read-after-arm, sigterm-on-arm.
set -u
[ -z "${LD_PRELOAD:-}" ] || exec env -u LD_PRELOAD "$0" "$@"
F=$REBAR_FAKE
settle() {
	local cfg sys v s e line ctl cap
	for cfg in "$F"/cfg/*; do
		[ -d "$cfg" ] && [ -e "$cfg/sysdir" ] || continue
		sys=$(<"$cfg/sysdir"); v=$(<"$sys/resource1_resize")
		[[ $v =~ ^[0-9]{1,2}$ ]] || continue
		ctl=$(<"$cfg/ctlreg") cap=$(<"$cfg/capreg")
		echo "$v" >>"$cfg/resizes"
		if [ -e "$cfg/no-resize" ]; then
			printf '%016x\n' $((0x$(<"$cfg/$cap") >> 4)) >"$sys/resource1_resize"
			continue
		fi
		read -r s _ < <(sed -n 2p "$sys/resource")
		e=$((s + (1 << (v + 20)) - 1))
		printf -v line '0x%016x 0x%016x 0x%016x' "$s" "$e" 0x14220c
		sed -i "2s/.*/$line/" "$sys/resource"
		printf '%08x\n' $(((0x$(<"$cfg/$ctl") & ~0x3f00) | v << 8)) >"$cfg/$ctl"
		printf '%016x\n' $((0x$(<"$cfg/$cap") >> 4)) >"$sys/resource1_resize"
	done
}
if [ "${1:-}" = --settle ]; then settle; exit 0; fi
[ "${1:-}" = -s ] && [ $# = 3 ] || { echo "fake setpci: usage: -s BDF REG[.L][=VAL[:MASK]]" >&2; exit 2; }
settle
bdf=$2 op=$3 cfg=$F/cfg/$2
[ -d "$cfg" ] || { echo "setpci: no device $bdf (stand-in)" >&2; exit 1; }
reg=$(printf '0x%x' "$((${op%%.*}))")
w=${op#*.}; w=${w%%=*}
if [[ $op != *=* ]]; then
	if [ "$reg" = 0x610 ] && [ -e "$cfg/kill-next-read" ]; then rm -f "$cfg/kill-next-read"; exit 143; fi
	v=$(cat "$cfg/$reg" 2>/dev/null || echo 00000000)
	case $w in B) echo "${v: -2}" ;; W) echo "${v: -4}" ;; *) echo "$v" ;; esac
	exit 0
fi
echo "$reg" >>"$cfg/written-regs"
[ ! -e "$cfg/fail-write-$reg" ] || { echo "setpci: write to $reg failed (stand-in failure mode)" >&2; exit 1; }
val=${op#*=} mask=ffffffff
if [[ $val == *:* ]]; then mask=${val#*:}; val=${val%:*}; fi
if [ -e "$cfg/latch-$reg" ]; then
	left=$(<"$cfg/latch-$reg")
	[ "$left" -gt 0 ] || { echo "$reg.L=$val:$mask (did not latch)" >>"$cfg/writes"; exit 0; }
	echo $((left - 1)) >"$cfg/latch-$reg"
fi
old=$((0x$(cat "$cfg/$reg" 2>/dev/null || echo 0)))
new=$(((old & ~0x$mask | 0x$val & 0x$mask) & 0xffffffff))
printf '%08x\n' "$new" >"$cfg/$reg"
echo "$reg.L=$val:$mask" >>"$cfg/writes"
[ "$reg" != 0x610 ] || [ ! -e "$cfg/sigterm-on-arm" ] || kill -TERM "$(cat "$F/arm.pid")"
if [ "$reg" = 0x610 ] && (((new >> 11) & 1)) && [ -e "$cfg/kill-read-after-arm" ]; then
	rm -f "$cfg/kill-read-after-arm"; touch "$cfg/kill-next-read"
fi
if [ "$reg" = 0x610 ] && [ -e "$cfg/xve" ]; then
	capr=$(<"$cfg/capreg")
	cap=$((0x$(<"$cfg/stockcap")))
	if (((new >> 11) & 1)) && [ ! -e "$cfg/no-widen" ]; then
		cap=$((cap | ((1 << (((new >> 7) & 0xf) + 11)) - 0x400)))
		[ ! -e "$cfg/narrow" ] || cap=$((cap & ~0x400))
	fi
	printf '%08x\n' "$cap" >"$cfg/$capr"
	[ ! -e "$cfg/no-mask" ] || cap=$((0x$(<"$cfg/stockcap")))
	f=$(<"$cfg/sysdir")/resource1_resize ro=0
	[ -w "$f" ] || { ro=1; chmod u+w "$f"; }
	printf '%016x\n' $((cap >> 4)) >"$f"
	[ "$ro" = 0 ] || chmod a-w "$f"
fi
EOF
printf '#!/bin/sh\nif [ "$*" = -u ]; then echo 0; else exec %s "$@"; fi\n' "$REAL_ID" >"$BIN/id"
printf '#!/bin/sh\nexit 0\n' >"$BIN/lspci"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/bin/sh\necho "systemctl $*" >>"%s/systemctl.calls"\ncase "$1" in is-enabled) [ -e "%s/enabled-$2" ] && { echo enabled; exit 0; }; echo disabled; exit 1 ;; esac\nexit 0\n' "$WORK" "$WORK" >"$BIN/systemctl"
printf '#!/bin/sh\necho "dkms $*" >>"%s/dkms.calls"\nexit 0\n' "$WORK" >"$BIN/dkms"
chmod 755 "$BIN"/*
export PATH="$BIN:$PATH" REBAR_FAKE=$FAKE

# --- fake tree ---------------------------------------------------------------------------------------------------
CASE_ON=1
begin() { # case-id description
	CASE=$1 DESC=$2 CDIR=$WORK/cases/$1 LOG=$WORK/cases/$1.log BAD="" K=0
	CASE_ON=1
	if [ ${#ONLY[@]} -gt 0 ]; then
		CASE_ON=0
		for p in "${ONLY[@]}"; do [[ $CASE != "$p"* ]] || CASE_ON=1; done
	fi
	ROOT=$CDIR/root
	mkdir -p "$ROOT/etc/modprobe.d" "$CDIR/run"
	echo "== $CASE: $DESC" >"$LOG"
	rm -rf "$FAKE"
	mkdir -p "$FAKE/sys/bus/pci/devices" "$FAKE/sys/bus/pci/drivers/nvidia" "$FAKE/sys/bus/pci/drivers/snd_hda_intel" \
		"$FAKE/sys/class/graphics" "$FAKE/cfg" "$FAKE/proc" "$FAKE/nv"
	: >"$FAKE/sys/bus/pci/drivers_probe"
	: >"$FAKE/proc/iomem"
	local hb=$FAKE/sys/devices/pci0000:00/0000:00:00.0
	mkdir -p "$hb" && echo 0x1022 >"$hb/vendor" && echo 0x1480 >"$hb/device" && echo 0x060000 >"$hb/class"
	ln -s "$hb" "$FAKE/sys/bus/pci/devices/0000:00:00.0"
}
bridges() { # domain BDF...
	local d=$FAKE/sys/devices/pci$1:00 b n=0
	shift
	for b; do
		d=$d/$b n=$((n + 1))
		[ -d "$d" ] && continue
		mkdir -p "$d"
		echo 0x060400 >"$d/class"; echo "(null)" >"$d/driver_override"
		if [ "$n" = 1 ]; then echo 0x8086 >"$d/vendor"; echo 0x2f04 >"$d/device"; else echo 0x10b5 >"$d/vendor"; echo 0x9797 >"$d/device"; fi
		{ for _ in $(seq 15); do printf '0x%016x 0x%016x 0x%016x\n' 0 0 0; done
			printf '0x%016x 0x%016x 0x%016x\n' 0x38fea0000000 0x38ff31ffffff 0x0010220c 0 0 0; } >"$d/resource"
	done
	echo "$d"
}
# card BDF [id=10de:2206] [sub=10de:146d] [class=0x030000] [bound=1] [console=1] [fb=NAME] [layout=xve|gb|plain]
#   [fail=610|resize|nospc|noent|noresize] [latch=N] [bar1=MiB] [r610=hex] [rbbc=hex] [v604=hex] [v60c=hex]
#   [hdr=hex] [under="RP BR..."] [audio=1|bound|<driver_override>] [start=hex] [bar1reg=hex] [bar3reg=hex]
# layout xve: GA102 chain 0x100 -> VSEC 0x600 -> 0x900 -> ReBAR 0xbb0 (BAR0, BAR1 at 0xbbc/0xbc0, BAR3);
# gb: 0x100 -> ReBAR 0x190 (BAR1 at 0x19c/0x1a0), no VSEC; plain: 0x100 -> ReBAR 0xbb0, no VSEC (a card that
# advertises its sizes by other means).
card() {
	local bdf=$1 id=10de:2206 sub=10de:146d class=0x030000 bound=0 console=0 fb="" layout=xve fail="" latch="" bar1=256
	local r610=00001001 rbbc=00001c00 v604=02410001 v60c=00001801 hdr=00 under="" audio="" start="" bar1reg="" bar3reg="" kv idx=0
	shift
	for kv; do local "$kv"; done
	[ ! -e "/proc/driver/nvidia/gpus/$bdf" ] || { echo "refusing: $bdf is a real GPU on this host" >&2; exit 2; }
	local parent=$FAKE/sys/devices/pci${bdf%%:*}:00
	# shellcheck disable=SC2086 # under is a word list
	[ -z "$under" ] || parent=$(bridges "${bdf%%:*}" $under)
	local sys=$parent/$bdf cfg=$FAKE/cfg/$bdf
	mkdir -p "$sys" "$cfg"
	ln -s "$sys" "$FAKE/sys/bus/pci/devices/$bdf"
	echo "(null)" >"$sys/driver_override"
	if [ -n "$audio" ]; then
		local a=$parent/${bdf%.*}.1
		mkdir -p "$a" && ln -s "$a" "$FAKE/sys/bus/pci/devices/${a##*/}"
		echo 0x10de >"$a/vendor"; echo 0x1aef >"$a/device"; echo 0x040300 >"$a/class"; echo "(null)" >"$a/driver_override"
		echo 0x10de >"$a/subsystem_vendor"; echo 0x146d >"$a/subsystem_device"
		case $audio in
			1) ;;
			bound) ln -s "$FAKE/sys/bus/pci/drivers/snd_hda_intel" "$a/driver" ;;
			*) echo "$audio" >"$a/driver_override" ;;
		esac
	fi
	echo "0x${id%%:*}" >"$sys/vendor"; echo "0x${id#*:}" >"$sys/device"; echo "$class" >"$sys/class"
	echo "0x${sub%%:*}" >"$sys/subsystem_vendor"; echo "0x${sub#*:}" >"$sys/subsystem_device"; echo "$console" >"$sys/boot_vga"
	if [ "$console" = 1 ]; then mkdir -p "$FAKE/sys/class/graphics/fb0" && ln -s "$sys" "$FAKE/sys/class/graphics/fb0/device"; fi
	if [ "$bound" = 1 ]; then ln -s "$FAKE/sys/bus/pci/drivers/nvidia" "$sys/driver"; fi
	K=$((K + 1))
	local s=$((${start:-0x380000000000 + K * 0x1000000000}))
	local r=$((${bar1reg:-s})) b3=$((s + 0x800000000)) r3
	r3=$((${bar3reg:-b3}))
	printf '%08x\n' $(((r & 0xffffffff) | 0xc)) >"$cfg/0x14"; printf '%08x\n' $((r >> 32)) >"$cfg/0x18"
	printf '%08x\n' $(((r3 & 0xffffffff) | 0xc)) >"$cfg/0x1c"; printf '%08x\n' $((r3 >> 32)) >"$cfg/0x20"
	echo 00000006 >"$cfg/0x4"
	printf '%08x\n' "0x$hdr" >"$cfg/0xe"
	printf '0x%016x 0x%016x 0x%016x\n' 0xfa000000 0xfaffffff 0x40200 "$s" $((s + (bar1 << 20) - 1)) 0x14220c 0 0 0 \
		"$b3" $((b3 + 0x2000000 - 1)) 0x14220c >"$sys/resource"
	[ -z "$fb" ] || printf '%x-%x : %s\n' "$s" $((s + 0x7fffff)) "$fb" >>"$FAKE/proc/iomem"
	while [ $((1 << idx)) -lt "$bar1" ]; do idx=$((idx + 1)); done
	printf '%016x\n' $((0x$rbbc >> 4)) >"$sys/resource1_resize"
	echo "$sys" >"$cfg/sysdir"
	local rb
	case $layout in
		xve)
			echo 60010001 >"$cfg/0x100"; echo 9001000b >"$cfg/0x600"; echo bb010019 >"$cfg/0x900"
			echo "$v604" >"$cfg/0x604"; echo "$v60c" >"$cfg/0x60c"; echo "$r610" >"$cfg/0x610"
			touch "$cfg/xve"; rb=$((0xbb0)) ;;
		gb) echo 19010001 >"$cfg/0x100"; rb=$((0x190)) ;;
		plain) echo bb010001 >"$cfg/0x100"; rb=$((0xbb0)) ;;
	esac
	printf '%08x\n' $((0x00010015)) >"$cfg/$(printf 0x%x "$rb")"
	echo 00000100 >"$cfg/$(printf 0x%x $((rb + 4)))"; echo 00000460 >"$cfg/$(printf 0x%x $((rb + 8)))"
	echo "$rbbc" >"$cfg/$(printf 0x%x $((rb + 12)))"; printf '%08x\n' $((idx << 8 | 1)) >"$cfg/$(printf 0x%x $((rb + 16)))"
	echo 00000200 >"$cfg/$(printf 0x%x $((rb + 20)))"; echo 00000503 >"$cfg/$(printf 0x%x $((rb + 24)))"
	printf 0x%x $((rb + 12)) >"$cfg/capreg"; printf 0x%x $((rb + 16)) >"$cfg/ctlreg"
	echo 00001c00 >"$cfg/stockcap"
	[ "$rbbc" = 00001c00 ] || [ "$layout" != xve ] || [ $(((0x$r610 >> 11) & 1)) = 1 ] || echo "$rbbc" >"$cfg/stockcap"
	case $fail in
		610) touch "$cfg/fail-write-0x610" ;;
		resize) chmod a-w "$sys/resource1_resize" ;;
		nospc) touch "$sys/resource1_resize.enospc" ;;
		noent) touch "$sys/resource1_resize.enoent" ;;
		noresize) touch "$cfg/no-resize" ;;
	esac
	[ -z "$latch" ] || echo "$latch" >"$cfg/latch-0x610"
	echo "card $bdf $id sub=$sub class=$class layout=$layout bound=$bound console=$console fb=$fb fail=${fail:-none} bar1=${bar1}MiB 0x610=$r610${under:+ under=$under}${audio:+ audio=$audio}" >>"$LOG"
}
reg() { cat "$FAKE/cfg/$1/$2" 2>/dev/null || echo 00000000; }
cap() { reg "$1" "$(<"$FAKE/cfg/$1/capreg")"; }
bar_mib() { local s e; read -r s e _ < <(sed -n 2p "$(<"$FAKE/cfg/$1/sysdir")/resource"); echo $(((e - s + 1) >> 20)); }
count() { [ -e "$FAKE/cfg/$1/$2" ] && wc -l <"$FAKE/cfg/$1/$2" || echo 0; }
ovr() { cat "$FAKE/sys/bus/pci/devices/$1/driver_override"; }
ovr_at() { sed -n "s/^$1 //p" "$FAKE/overrides-at-modprobe" 2>/dev/null; }
lines() { [ -e "$FAKE/$1" ] && wc -l <"$FAKE/$1" || echo 0; }
vram() { # BDF MIB [ids]: seed the VRAM record
	mkdir -p "$ROOT/etc/geforce-bar1-resize"
	echo "$1 ${3:-$(ids "$1")} $2 615.71.09 2026-11-01" >>"$ROOT/etc/geforce-bar1-resize/vram"
}
ids() { local d=$FAKE/sys/bus/pci/devices/$1 v; v="$(cat "$d/vendor"):$(cat "$d/device")/$(cat "$d/subsystem_vendor"):$(cat "$d/subsystem_device")"; echo "${v//0x/}"; }

# --- runners -----------------------------------------------------------------------------------------------------
GBR_ENV() { echo "GBR_ROOT=$ROOT GBR_STATE_DIR=$ROOT/etc/geforce-bar1-resize GBR_RUN_DIR=$CDIR/run GBR_MODPROBE_DIR=$ROOT/etc/modprobe.d GBR_NV_PROC=$FAKE/nv"; }
conf() { mkdir -p "$ROOT/etc" && printf '%s\n' "$@" >"$ROOT/etc/geforce-bar1-resize.conf"; }
oldconf() { mkdir -p "$ROOT/etc" && printf '%s\n' "$@" >"$ROOT/etc/rebar-arm.conf"; }
gbr() { # subcommand args...: $GBR_SCRIPT, else the installed copy if there is one; output in $CDIR/out (also $CDIR/arm.out)
	local script=${GBR_SCRIPT:-$ROOT/usr/local/sbin/geforce-bar1-resize}
	[ -x "$script" ] || script=$SRC/scripts/geforce-bar1-resize
	echo "\$ ${script#"$WORK"/} $*" >>"$LOG"
	RC=0
	# shellcheck disable=SC2046 # word list of assignments
	env $(GBR_ENV) LD_PRELOAD="$BIN/standin-open.so" "$script" "$@" >"$CDIR/out" 2>&1 &
	echo $! >"$FAKE/arm.pid"
	wait $! || RC=$?
	setpci --settle
	cp "$CDIR/out" "$CDIR/arm.out"
	sed 's/^/  | /' "$CDIR/out" >>"$LOG"; echo "  rc=$RC" >>"$LOG"
}
boot() { # boot with the config, its log going to the case directory
	[ -e "$ROOT/etc/geforce-bar1-resize.conf" ] || [ -e "$ROOT/etc/rebar-arm.conf" ] || conf ""
	local c=$ROOT/etc/geforce-bar1-resize.conf
	[ -e "$c" ] || c=$ROOT/etc/rebar-arm.conf
	{ cat "$c"; echo "LOG=$CDIR/gbr.log"; } >"$CDIR/run.conf"
	GBR_CONF=$CDIR/run.conf gbr boot "$@"
}
inst() { # install.sh args (always --root $ROOT --yes); sets RC
	echo "\$ install.sh --root \$ROOT --yes $*" >>"$LOG"
	RC=0
	# shellcheck disable=SC2046
	env $(GBR_ENV) GBR_ROOT= GBR_STATE_DIR= GBR_MODPROBE_DIR= "$SRC/install.sh" --root "$ROOT" --yes "$@" </dev/null >"$CDIR/install.out" 2>&1 || RC=$?
	sed 's/^/  | /' "$CDIR/install.out" >>"$LOG"; echo "  rc=$RC" >>"$LOG"
}
uninst() {
	echo "\$ uninstall.sh --root \$ROOT $*" >>"$LOG"
	RC=0; "$SRC/uninstall.sh" --root "$ROOT" "$@" >"$CDIR/uninstall.out" 2>&1 || RC=$?
	sed 's/^/  | /' "$CDIR/uninstall.out" >>"$LOG"; echo "  rc=$RC" >>"$LOG"
}

# --- checks ------------------------------------------------------------------------------------------------------
check() { # description command...
	local what=$1; shift
	if "$@" >>"$LOG" 2>&1; then echo "  ok   $what" >>"$LOG"; else echo "  FAIL $what" >>"$LOG"; BAD+="$what; "; fi
}
eq() { [ "$1" = "$2" ] || { echo "    got '$1', want '$2'"; return 1; }; }
has() { grep -qE -- "$2" "$1" || { echo "    /$2/ not in ${1#"$WORK"/}"; return 1; }; }
hasnt() { ! grep -qE -- "$2" "$1" || { echo "    /$2/ found in ${1#"$WORK"/}"; return 1; }; }
before() {
	local a b
	a=$(grep -nE -- "$2" "$1" | tail -n 1 | cut -d: -f1) b=$(grep -nE -- "$3" "$1" | head -n 1 | cut -d: -f1)
	[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || { echo "    /$2/ (line ${a:-none}) not before /$3/ (line ${b:-none})"; return 1; }
}
absent() { [ ! -e "$1" ] && [ ! -L "$1" ] || { echo "    ${1#"$WORK"/} exists"; return 1; }; }
present() { [ -e "$1" ] || { echo "    ${1#"$WORK"/} missing"; return 1; }; }
OPTF=etc/modprobe.d/zz-geforce-bar1-resize.conf
opt_is() { # exact NVreg_RegistryDwordsPerDevice value
	has "$ROOT/$OPTF" "^options nvidia NVreg_RegistryDwordsPerDevice=\"$1\"\$" && [ "$(grep -c '^options' "$ROOT/$OPTF")" = 1 ]
}
large() { # BDF... armed for n = 9, capability wide, BAR1 32 GiB, resized once
	local b
	for b; do check "$b armed, 32 GiB" eq "$(reg "$b" 0x610) $(cap "$b") $(bar_mib "$b") $(count "$b" resizes)" "00001c81 000ffc00 32768 1"; done
}
stock() { # BDF... untouched: stock registers, 256 MiB, no config write, no resize
	local b
	for b; do check "$b untouched" eq "$(reg "$b" 0x610) $(cap "$b") $(bar_mib "$b") $(count "$b" writes)/$(count "$b" resizes)" "00001001 00001c00 256 0/0"; done
}
back_stock() {
	local b
	for b; do check "$b disarmed, stock" eq "$(reg "$b" 0x610) $(cap "$b") $(bar_mib "$b")" "00001001 00001c00 256"; done
}
armed_large() {
	local b
	for b; do check "$b armed, 32 GiB via layout" eq "$(reg "$b" 0x610) $(cap "$b") $(bar_mib "$b") $(count "$b" resizes)" "00001c81 000ffc00 32768 0"; done
}
no_hold() { local b; for b; do check "$b driver_override untouched" eq "$(ovr "$b")" "(null)"; done; }
untouched_610() { local b; for b; do check "$b: no config write" eq "$(count "$b" writes)" 0; done; }
no_vsec_write() { # BDF...: no write to any register at 0x600..0x6ff
	local b
	for b; do check "$b: no write at 0x600-0x6ff" eq "$(grep -c '^0x6[0-9a-f][0-9a-f]$' "$FAKE/cfg/$b/written-regs" 2>/dev/null || echo 0)" 0; done
}
same_tree() { # file-before file-after: identical, or the first lines of the difference
	cmp -s "$1" "$2" && return 0
	diff "$1" "$2" | head -n 8
	return 1
}

FAILS=0 SKIPS=0 ROWS=() SKIP=""
end_case() {
	local r=PASS
	if [ -n "$BAD" ]; then r=FAIL FAILS=$((FAILS + 1))
	elif [ -n "$SKIP" ]; then r=SKIP SKIPS=$((SKIPS + 1)); fi
	echo "$r  $CASE${BAD:+  log: $LOG  (failed: ${BAD%; })}${SKIP:+  ($SKIP)}"
	ROWS+=("$(printf '%-30s %-4s %s' "$CASE" "$r" "$DESC")")
}
# run a case body only when selected
run_case() { # id description function
	begin "$1" "$2"
	[ "$CASE_ON" = 1 ] || return 0
	SKIP=""
	"$3"
	end_case
}

# card addresses and switch paths the case files use
# shellcheck disable=SC2034
A=0000:05:00.0 B=0000:06:00.0 C=0000:41:00.0 D=0000:c1:00.0 E=0001:01:00.0
# shellcheck disable=SC2034
S1=0000:0c:00.0 S2=0000:0d:00.0
# shellcheck disable=SC2034
U1="0000:00:03.0 0000:09:00.0 0000:0a:08.0" U2="0000:00:03.0 0000:09:00.0 0000:0a:0c.0"
# shellcheck disable=SC2034
T=10de:1e07

T0=$(date +%s)
# shellcheck source=/dev/null # checked on their own
. "$HERE/cases-boot.sh"
# shellcheck source=/dev/null
. "$HERE/cases-install.sh"
# shellcheck source=/dev/null
. "$HERE/cases-p2p.sh"
# shellcheck source=/dev/null
. "$HERE/cases-more.sh"

echo
printf '%-30s %-4s %s\n' case res checked
printf '%s\n' "${ROWS[@]}"
echo "${#ROWS[@]} cases: $((${#ROWS[@]} - FAILS - SKIPS)) passed, $FAILS failed, $SKIPS skipped in $(($(date +%s) - T0)) s"
if [ "$FAILS" = 0 ] && [ "$OWN_WORK" = 1 ]; then
	rm -rf "$WORK"
else
	echo "logs: $WORK/cases"
fi
[ "$FAILS" -le 125 ] || FAILS=125
exit "$FAILS"
