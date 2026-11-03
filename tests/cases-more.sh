# shellcheck shell=bash disable=SC2154,SC2034,SC2086 # run.sh sets the variables; card addresses never need quoting
# SPDX-License-Identifier: MIT
# More cases for tests/run.sh (sourced last): discovery reasons, S1-S6 one by one, labels, sizes, routes, dry run,
# record, config precedence, driver option merges, console rules, best effort, migration edges and recovery.

sysdir() { cat "$FAKE/cfg/$1/sysdir"; }
snap() { { tree_sum "$FAKE" | grep -v -e '^\./arm\.pid ' -e '^\./smi\.calls '; echo "--- root"; tree_sum "$ROOT"; } 2>/dev/null; } # every fake file (not the harness's arm.pid and nvidia-smi call log) and the staging root
move_rebar() { # BDF: ReBAR capability moved to 0x300 (0x100 -> 0x300 -> 0x600 -> 0x900), BAR1 entry at 0x30c
	local c=$FAKE/cfg/$1 r
	for r in 0xbb0 0xbb4 0xbb8 0xbbc 0xbc0 0xbc4 0xbc8; do rm -f "$c/$r"; done
	echo 30010001 >"$c/0x100"; echo 00010019 >"$c/0x900"
	echo 60010015 >"$c/0x300"; echo 00000100 >"$c/0x304"; echo 00000460 >"$c/0x308"
	echo 00001c00 >"$c/0x30c"; echo 00000801 >"$c/0x310"; echo 00000200 >"$c/0x314"; echo 00000503 >"$c/0x318"
	echo 0x30c >"$c/capreg"; echo 0x310 >"$c/ctlreg"
}
enlarged() { # BDF 0x610 MiB: armed to that value and BAR1 that size
	check "$1 0x610 $2, BAR1 $3 MiB" eq "$(reg "$1" 0x610) $(bar_mib "$1")" "$2 $3"
}

# --- discovery ------------------------------------------------------------------------------------------------------
c80() {
	card $A class=0x030200; card $B id=1002:73bf sub=1002:0e3a; card $C bound=1; card $D; card $S1 audio=1
	mkdir -p "$FAKE/sys/bus/pci/drivers/vfio-pci"; ln -s "$FAKE/sys/bus/pci/drivers/vfio-pci" "$(sysdir $D)/driver"
	for b in $A $C $D $S1; do vram $b 20480; done
	boot; check "rc 0" eq "$RC" 0
	large $A
	check "0302 without a framebuffer: no console line" hasnt "$CDIR/out" "$A console card"
	check "non-NVIDIA VGA never listed by auto" hasnt "$CDIR/out" "$B"
	check "bound to nvidia: reported" has "$CDIR/out" "$C already bound to nvidia, skip$"
	check "bound to vfio-pci: reported" has "$CDIR/out" "$D already bound to vfio-pci, skip$"
	stock $C $D; untouched_610 $B
	check "audio function never listed" hasnt "$CDIR/out" "0000:0c:00\.1"
	large $S1
	conf "CARDS=\"$B\""; boot
	check "explicit non-NVIDIA: not a candidate" has "$CDIR/out" "$B 1002:73bf/1002:0e3a: not a candidate: not an NVIDIA function$"
	untouched_610 $B
}
run_case 80-discovery-classes "auto: 0302 enlarged; non-NVIDIA, bound (nvidia, vfio-pci) and audio functions left alone" c80

c81() {
	card $A; card $B; card $C id=10de:2684 sub=1458:4105; card $D id=10de:2684 sub=10de:16f3
	for b in $A $B $C $D; do vram $b 20480; done
	echo 00010001 >"$FAKE/cfg/$A/0x100" # the chain ends at AER: no ReBAR capability
	rm "$(sysdir $B)/resource1_resize"
	conf 'EXCLUDE="10de:2684/1458:4105"'
	boot --dry-run
	check "no ReBAR capability" has "$CDIR/out" "$A 10de:2206/10de:146d: not a candidate: no ReBAR capability with a BAR1 entry \(pre-Turing\?\)$"
	check "no resource1_resize" has "$CDIR/out" "$B 10de:2206/10de:146d: not a candidate: no resource1_resize"
	check "EXCLUDE id/subsys" has "$CDIR/out" "$C 10de:2684/1458:4105: not a candidate: excluded by config$"
	check "same id, other subsys: planned" has "$CDIR/out" "$D would arm 0x610 VAL=9"
	conf 'EXCLUDE="10de:2684"'; boot --dry-run
	check "EXCLUDE vendor:device: $C" has "$CDIR/out" "$C 10de:2684/1458:4105: not a candidate: excluded by config$"
	check "EXCLUDE vendor:device: $D" has "$CDIR/out" "$D 10de:2684/10de:16f3: not a candidate: excluded by config$"
	conf ""; boot --dry-run --card 10de:2684/10de:16f3
	check "--card id/subsys selects only $D" eq "$(grep -c 'would arm' "$CDIR/out")/$(grep -c "$D would arm" "$CDIR/out")" 1/1
	boot; check "rc 0" eq "$RC" 0
	untouched_610 $A $B; large $C $D
}
run_case 81-discovery-reasons "no ReBAR capability, no resource1_resize, EXCLUDE by id and id/subsys, --card by id/subsys" c81

# --- S1-S6 ----------------------------------------------------------------------------------------------------------
c82() {
	card $A layout=gb; card $B v604=02410002; card $C v60c=00001809; card $D r610=00000081; card $S1; card $S2 hdr=80
	move_rebar $S1
	for b in $A $B $C $D $S1 $S2; do vram $b 20480; done
	GBR_CONF=/nonexistent gbr check $A $B $C $D $S1 $S2; check "check: rc 1 (cards without a route)" eq "$RC" 1
	check "check S1" has "$CDIR/out" "^  FAIL S1 no VSEC \(ID 000b v1\) at 0x600 in the capability chain$"
	check "check S2" has "$CDIR/out" "^  FAIL S2 VSEC header at 0x604 reads 02410002, not ID 0001 rev 1 len 024$"
	check "check S3 (reserved bit 3)" has "$CDIR/out" "^  FAIL S3 0x60c reads 00001809: FB_SIZE_OVERRIDE not supported or reserved bits set$"
	check "check S4 (VAL without EN)" has "$CDIR/out" "^  FAIL S4 0x610 reads 00000081: reserved bits set or an unknown stock value$"
	check "check S5" has "$CDIR/out" "^  FAIL S5 ReBAR capability at 0x300, BAR1 entry at 0x30c: not the XVE layout \(0xbb0, 0xbbc\)$"
	check "check S6 (multi-function bit alone passes, header type 0)" hasnt "$CDIR/out" "S6 not a type 0 endpoint \(header type 80\)"
	check "check: S1-S3 failures never read 0x610" eq "$(grep -c '0x610 not read' "$CDIR/out")" 3
	check "check: S2 failed, S3/S4 not checked" has "$CDIR/out" "^  --   S3 not checked \(an earlier check failed\)$"
	echo 00000001 >"$FAKE/cfg/$S2/0xe"
	boot; check "rc 0" eq "$RC" 0
	local b s
	for s in "$A|S1" "$B|S2" "$C|S3" "$D|S4" "$S1|S5" "$S2|S6"; do
		b=${s%%|*}
		check "boot ${s#*|} logged, card skipped" has "$CDIR/out" "$b 10de:2206/10de:146d: ${s#*|} "
		check "boot ${s#*|}: no 0x610 route for $b" has "$CDIR/out" "$b 0x610 route not available$"
		check "boot ${s#*|}: $b skip line" has "$CDIR/out" "$b route skip: capability lists up to 256 MiB < target 32768 MiB, and the 0x610 route is not available$"
	done
	untouched_610 $A $B $C $D $S1 $S2
	no_vsec_write $A $B $C $D $S1 $S2
	check "nothing resized" eq "$(for b in $A $B $C $D $S1 $S2; do count "$b" resizes; done | sort -u)" 0
}
run_case 82-s1-s6-each "check and boot refuse 0x610 on each S1-S6 failure (new S3/S4 values); nothing written" c82

# --- labels ---------------------------------------------------------------------------------------------------------
c83() {
	card $A; card $B rbbc=000ffc00; card $C sub=10de:1454; card $D bar1=32768 r610=00001c81 rbbc=000ffc00
	card $S1 id=10de:2684 sub=1458:4105; card $S2 id=10de:2684 sub=1458:4105
	for b in $A $B $C $D; do vram $b 20480; done; vram $S1 49140; vram $S2 20480
	sed '/^\t"10de:2206\/10de:146d 0x610 9 615.71.09 verified"$/a\	"10de:2684/1458:4105 0x610 10 615.71.09 reported"' \
		"$SRC/scripts/geforce-bar1-resize" >"$CDIR/gbr-reported"
	chmod 755 "$CDIR/gbr-reported"
	check "label copy differs by one row" eq "$(diff "$SRC/scripts/geforce-bar1-resize" "$CDIR/gbr-reported" | grep -c '^>')" 1
	GBR_SCRIPT=$CDIR/gbr-reported boot --dry-run
	check "verified: id+subsys, 0x610, n 9" has "$CDIR/out" "$A 10de:2206/10de:146d \(verified\) VRAM 20480 MiB"
	check "resize-only route: untested" has "$CDIR/out" "$B 10de:2206/10de:146d \(untested\)"
	check "other subsystem: untested" has "$CDIR/out" "$C 10de:2206/10de:1454 \(untested\)"
	check "armed earlier, already big: verified (route 0x610)" has "$CDIR/out" "$D 10de:2206/10de:146d \(verified\) VRAM 20480 MiB \(record\), target 32768 MiB, BAR1 32768 MiB$"
	check "reported row, n 10" has "$CDIR/out" "$S1 10de:2684/1458:4105 \(reported\) VRAM 49140 MiB"
	check "reported ids at another n: untested" has "$CDIR/out" "$S2 10de:2684/1458:4105 \(untested\) VRAM 20480 MiB"
	GBR_CONF=/nonexistent GBR_SCRIPT=$CDIR/gbr-reported gbr check $A $S1 $S2
	check "check: label verified" eq "$(grep -c '^  label   verified$' "$CDIR/out")" 1
	check "check: label reported" eq "$(grep -c '^  label   reported$' "$CDIR/out")" 1
	check "check: untested names the miss" has "$CDIR/out" "^  label   untested \(no compatibility report matches 10de:2684/1458:4105 route 0x610 n=9; docs/hardware.md\)$"
	gbr boot --dry-run; check "shipped table: 2684/1458:4105 untested" has "$CDIR/out" "$S1 10de:2684/1458:4105 \(untested\)"
	check "labels never gate: every card planned" eq "$(grep -cE 'would (arm|resize)' "$CDIR/out")" 5
}
run_case 83-labels "verified / reported (one-row copy) / untested in boot and check; labels never decide" c83

# --- sizing ---------------------------------------------------------------------------------------------------------
c84() {
	card $A; card $B; card $C; card $D; card $S1
	vram $A 8188; vram $B 12282; vram $C 20480; vram $D 24564; vram $S1 49140
	boot; check "rc 0" eq "$RC" 0
	enlarged $A 00001b81 8192; enlarged $B 00001c01 16384; enlarged $C 00001c81 32768; enlarged $D 00001c81 32768; enlarged $S1 00001d01 65536
	check "8188 MiB -> 8 GiB" has "$CDIR/out" "$A .* VRAM 8188 MiB \(record\), target 8192 MiB, BAR1 256 MiB$"
	check "12282 MiB -> 16 GiB" has "$CDIR/out" "$B .* VRAM 12282 MiB \(record\), target 16384 MiB"
	check "24564 MiB -> 32 GiB" has "$CDIR/out" "$D .* VRAM 24564 MiB \(record\), target 32768 MiB"
	check "49140 MiB -> 64 GiB, VAL 10" has "$CDIR/out" "$S1 route 0x610 VAL=10: arm, then resize to 65536 MiB$"
	check "order: 64 GiB first" before "$CDIR/out" "$S1 armed and resized" "$C route 0x610"
	check "order: 8 GiB last" before "$CDIR/out" "$B armed and resized" "$A route 0x610"
	check "one resize each" eq "$(for b in $A $B $C $D $S1; do count "$b" resizes; done | sort -u)" 1
}
run_case 84-sizing-table "VRAM 8188/12282/20480/24564/49140 MiB -> n 7/8/9/9/10, largest first" c84

c85() {
	card $A; card $B r610=00001d01 rbbc=001ffc00; card $C; card $D
	vram $B 20480
	conf "SIZE=48G" 'declare -A CARD=(' "  [$B]=\"size=auto\"" "  [$C]=\"size=512G\"" "  [$D]=\"size=100M\"" ')'
	boot; check "rc 0" eq "$RC" 0
	enlarged $A 00001d01 65536
	check "SIZE=48G rounds up to 64 GiB" has "$CDIR/out" "$A .* size from config, target 65536 MiB"
	check "armed earlier at VAL 10, target n 9: VAL kept (never arm below the list)" has "$CDIR/out" "$B route 0x610 VAL=10: arm, then resize to 32768 MiB$"
	check "$B: no 0x610 write, 0x610 kept, 32 GiB" eq "$(count $B writes) $(reg $B 0x610) $(bar_mib $B)" "0 00001d01 32768"
	enlarged $C 00001e81 524288
	check "n 13 = 512 GiB" has "$CDIR/out" "$C armed and resized to 524288 MiB$"
	check "size=100M below BAR1: never shrunk" has "$CDIR/out" "$D BAR1 already 256 MiB, skip$"
	stock $D
	conf "SIZE=1T"; boot --dry-run
	check "SIZE=1T invalid" has "$CDIR/out" "SIZE=1T invalid \(auto, 0..13 or 64M..512G\); using auto$"
	conf "SIZE=32M"; boot --dry-run
	check "SIZE=32M invalid" has "$CDIR/out" "SIZE=32M invalid"
	conf 'declare -A CARD=(' "  [$D]=\"size=14\"" ')'; boot --dry-run
	check "per-card size=14 invalid, ignored" has "$CDIR/out" "$D CARD\[$D\]: size=14 invalid \(auto, 0..13, 64M..512G\); ignored$"
}
run_case 85-sizing-clamp "SIZE rounding, n 13 max, VAL never below the listed sizes, never shrink, bounds" c85

# --- routes ---------------------------------------------------------------------------------------------------------
c86() {
	card $A; card $B rbbc=000ffc00; card $C; card $D; card $S1; card $S2 latch=1
	move_rebar $S1
	for b in $A $B $C $D $S1 $S2; do vram $b 20480; done
	conf "ROUTE=skip"; boot --dry-run
	check "ROUTE=skip: every card skipped" eq "$(grep -c 'route skip: route=skip in config$' "$CDIR/out")" 6
	conf "ROUTE=resize" 'declare -A CARD=(' "  [$B]=\"route=0x610\"" "  [$C]=\"route=skip\"" "  [$D]=\"route=auto\"" "  [$S1]=\"route=0x610\"" "  [$S2]=\"route=auto\"" ')'
	boot; check "rc 0" eq "$RC" 0
	check "ROUTE=resize, not listed: skip, 0x610 never written" has "$CDIR/out" "$A route skip: ReBAR capability does not advertise 32768 MiB \(resource1_resize mask [0-9a-f]+\)$"
	check "ROUTE=resize, not listed: why" has "$CDIR/out" "$A route resize never writes 0x610, skip$"
	untouched_610 $A
	check "route=0x610 on a natively listing card: armed" has "$CDIR/out" "$B route 0x610 VAL=9: arm, then resize to 32768 MiB$"
	enlarged $B 00001c81 32768
	check "per-card route=skip beats ROUTE" has "$CDIR/out" "$C route skip: route=skip in config$"
	stock $C
	enlarged $D 00001c81 32768
	check "route=0x610 needs S5 (only 0x610! waives it)" has "$CDIR/out" "$S1 route skip: .*the 0x610 route is not available$"
	untouched_610 $S1
	check "latch=1 (first write latches): armed" has "$CDIR/out" "$S2 armed and resized to 32768 MiB$"
	check "$S2 one write" eq "$(count $S2 writes)" 1
}
run_case 86-routes "ROUTE=skip/resize globally, per-card route overrides, 0x610 on a listing card, S5 kept, latch" c86

# --- dry run --------------------------------------------------------------------------------------------------------
c87() {
	card $A; card $B layout=plain rbbc=000ffc00; card $C console=1 fb=BOOTFB; card $D class=0x030200 fb=efifb
	card $S1 under="$U1" fail=nospc audio=1; card $S2 bound=1
	for b in $A $B $C $D $S1 $S2; do vram $b 20480; done
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMDynBar1P2PEnable=0;\"" >"$ROOT/$OPTF"
	echo "$A 0x610 enlarged" >"$CDIR/run/cards"
	conf LAYOUT=auto
	{ cat "$ROOT/etc/geforce-bar1-resize.conf"; echo "LOG=$CDIR/gbr.log"; } >"$CDIR/run.conf"
	snap >"$CDIR/tree.0"; ls -l "$CDIR/run" >"$CDIR/run.0"
	GBR_CONF=$CDIR/run.conf gbr boot --dry-run; check "dry run rc 0" eq "$RC" 0
	check "console line (would remove)" has "$CDIR/out" "$C console card: the kernel would remove the firmware framebuffer \(BOOTFB@BAR1\)"
	check "switch card: a plain plan line" has "$CDIR/out" "$S1 would arm 0x610 VAL=9"
	GBR_CONF=$CDIR/run.conf gbr plan --card $A
	GBR_CONF=$CDIR/run.conf gbr check
	GBR_CONF=$CDIR/run.conf gbr driver-option --print
	GBR_CONF=$CDIR/run.conf gbr driver-option --check
	snap >"$CDIR/tree.1"; ls -l "$CDIR/run" >"$CDIR/run.1"
	check "fake devices and root byte-identical" same_tree "$CDIR/tree.0" "$CDIR/tree.1"
	check "run dir unchanged" same_tree "$CDIR/run.0" "$CDIR/run.1"
	check "no module load" absent "$FAKE/modprobe.calls"
	check "no log file" absent "$CDIR/gbr.log"
	check "no config write at all" eq "$(cat "$FAKE"/cfg/*/written-regs 2>/dev/null | wc -l)" 0
}
run_case 87-dry-run-tree "boot --dry-run, plan, check, driver-option --print/--check: every fake file unchanged" c87

# --- VRAM record ----------------------------------------------------------------------------------------------------
c88() {
	card $A bound=1; card $B bound=1 id=10de:2684 sub=1458:4105
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	gbr record; check "nvidia-smi fails: nothing recorded" has "$CDIR/out" "record: nvidia-smi failed; nothing recorded$"
	check "no record file" absent "$ROOT/etc/geforce-bar1-resize/vram"
	printf '00000000:05:00.0, 20480, 615.71.09\n00000000:07:00.0, 8192, 615.71.09\n00000000:06:00.0, N/A, 615.71.09\n' >"$FAKE/smi"
	conf DRIVER_OPTION=off
	gbr record; check "rc 0" eq "$RC" 0
	check "absent card not recorded" has "$CDIR/out" "record: cannot use '00000000:07:00.0, 8192, 615.71.09'$"
	check "unparsable size not recorded" has "$CDIR/out" "record: cannot use '00000000:06:00.0, N/A, 615.71.09'$"
	check "record has only $A" eq "$(grep -vc '^#' "$ROOT/etc/geforce-bar1-resize/vram")" 1
	check "DRIVER_OPTION=off: no option file from record" absent "$ROOT/$OPTF"
	# the card at $A swapped for another model: re-recorded with the new ids; boot uses it
	echo 0x2684 >"$(sysdir $A)/device"; echo 0x1458 >"$(sysdir $A)/subsystem_vendor"; echo 0x4105 >"$(sysdir $A)/subsystem_device"
	printf '00000000:05:00.0, 24564, 615.71.09\n' >"$FAKE/smi"
	gbr record $A; check "swapped card re-recorded" has "$ROOT/etc/geforce-bar1-resize/vram" "^$A 10de:2684/1458:4105 24564 615.71.09 [0-9-]+$"
	rm "$(sysdir $A)/driver"
	conf ""; boot; check "boot uses the new record" has "$CDIR/out" "$A 10de:2684/1458:4105 \(untested\) VRAM 24564 MiB \(record\), target 32768 MiB"
}
run_case 88-record-edges "record: nvidia-smi failure, absent/unparsable rows, DRIVER_OPTION=off, card swap" c88

# --- config precedence ----------------------------------------------------------------------------------------------
c89() {
	card $A; card $B; card $C sub=10de:1454; card $D; card $S1 id=10de:2204
	for b in $A $B $C $D $S1; do vram $b 20480; done
	conf "SIZE=9" 'declare -A CARD=(' "  [$A]=\"ids=10de:2206/10de:146d size=8\"" '  [10de:2206/10de:146d]="size=10"' '  [10de:2206]="size=11"' "  [$D]=\"enable=no\"" ')'
	boot --dry-run
	check "BDF entry first" has "$CDIR/out" "$A would arm 0x610 VAL=8 "
	check "then id/subsys" has "$CDIR/out" "$B would arm 0x610 VAL=10 "
	check "then id" has "$CDIR/out" "$C would arm 0x610 VAL=11 "
	check "enable=no" has "$CDIR/out" "$D route skip: enable=no in config$"
	check "no entry: global SIZE" has "$CDIR/out" "$S1 would arm 0x610 VAL=9 "
	GBR_CONF=$ROOT/etc/geforce-bar1-resize.conf gbr check $A $B $C
	check "check names the entry used" eq "$(grep -cE "^  config  CARD\[($A|10de:2206/10de:146d|10de:2206)\]$" "$CDIR/out")" 3
}
run_case 89-config-precedence "CARD[BDF] > CARD[id/subsys] > CARD[id] > global; enable=no" c89

c109() {
	# enable=no sorts last (no size); the run must still reach the layout phase and the state file
	card $A; card $S1 under="$U1" fail=nospc audio=1; card $D
	vram $A 20480; vram $S1 20480; vram $D 20480
	conf LAYOUT=auto 'declare -A CARD=(' "  [$D]=\"enable=no\"" ')'
	boot; check "rc 0" eq "$RC" 0
	check "enable=no logged" has "$CDIR/out" "$D route skip: enable=no in config$"
	stock $D; large $A; armed_large $S1
	check "layout phase ran" has "$CDIR/out" "driver hold released on"
	check "state file written" has "$CDIR/run/cards" "^$S1 0x610 enlarged$"
	GBR_CONF=$ROOT/etc/geforce-bar1-resize.conf gbr check $A $D
	check "check reaches the disabled card" has "$CDIR/out" "^  PLAN    skip: enable=no in config$"
	check "check: no shell error" hasnt "$CDIR/out" "unbound variable"
}
run_case 109-enable-no-boot "enable=no card: boot completes (layout phase, state), check lists it" c109

c110() {
	# repair re-arms only cards whose configured route can be 0x610
	card $A bound=1 bar1=32768; card $B bound=1 bar1=32768; card $C bound=1 bar1=32768; card $D bound=1 bar1=32768
	for b in $A $B $C $D; do vram $b 20480; done
	conf 'declare -A CARD=(' "  [$A]=\"enable=no\"" "  [$B]=\"route=skip\"" "  [$C]=\"route=resize\"" ')'
	GBR_CONF=$ROOT/etc/geforce-bar1-resize.conf gbr repair
	check "enable=no: skipped" has "$CDIR/out" "$A repair: enable=no in config, skip$"
	check "route=skip: skipped" has "$CDIR/out" "$B repair: route=skip in config, 0x610 is not this card's route; skip$"
	check "route=resize: skipped" has "$CDIR/out" "$C repair: route=resize in config, 0x610 is not this card's route; skip$"
	untouched_610 $A $B $C
	check "$D re-armed" has "$CDIR/out" "$D bound; re-armed after reset"
	conf "ROUTE=resize"; GBR_CONF=$ROOT/etc/geforce-bar1-resize.conf gbr repair $A
	check "global ROUTE=resize: skipped" has "$CDIR/out" "$A repair: route=resize in config"
	untouched_610 $A
}
run_case 110-repair-config "repair skips enable=no, route=skip and route=resize (per card and global)" c110

c111() {
	# values that would go into the root-sourced config are refused unless they fit the schema
	card $A; smi_for $A:20480
	local bad
	for bad in "REBAR_BDFS='$A;\$(id)'" "REBAR_N=99" "REBAR_LAYOUT='on;\`id\`'"; do
		rm -rf "${ROOT:?}"/*; mkdir -p "$ROOT/etc/modprobe.d"
		old_install 1 "$A"
		echo "$bad" >>"$ROOT/etc/rebar-arm.conf"
		inst; check "old config $bad: refused" eq "$RC" 1
		check "$bad: named" has "$CDIR/install.out" "rebar-arm.conf: ${bad%%=*}="
		check "$bad: nothing written" has "$CDIR/install.out" "^  fix it \(or remove the line\) and rerun\. Nothing was written$"
		check "$bad: no new config" absent "$ROOT/etc/geforce-bar1-resize.conf"
		check "$bad: old install left in place" eq "$([ -e "$ROOT/etc/rebar-arm.conf" ] && [ -L "$ROOT/etc/systemd/system/sysinit.target.wants/rebar-arm.service" ] && echo kept)" kept
	done
	rm -rf "${ROOT:?}"/*; mkdir -p "$ROOT/etc/modprobe.d"
	old_install 1 "$A" "pci=$A;RMForceStaticBar1=0;RmFoo=\$(id);"
	inst; check "old option file token \$(id): refused" eq "$RC" 1
	check "token named" has "$CDIR/install.out" "zz-nvidia-static-bar1.conf: the keys 'RmFoo=\\\$\(id\);' for $A are not"
	check "no new config" absent "$ROOT/etc/geforce-bar1-resize.conf"
	rm -rf "${ROOT:?}"/*; mkdir -p "$ROOT/etc/modprobe.d"
	inst --cards "$A;\$(id)"; check "--cards with \$(): refused" eq "$RC" 1
	inst --exclude "10de:2684\`id\`"; check "--exclude with a backtick: refused" eq "$RC" 1
	inst --size 1M; check "--size 1M (below 64M): refused" eq "$RC" 1
	inst --size 513G; check "--size 513G (above 512G): refused" eq "$RC" 1
	check "nothing installed" absent "$ROOT/etc/geforce-bar1-resize.conf"
	inst --cards "${A^^} 01:00.0" --exclude "10de:2684/1458:4105" --size 512G; check "valid --cards/--exclude/--size accepted" eq "$RC" 0
}
run_case 111-migrate-validate "migrated REBAR_* values, option-file tokens and --cards/--exclude/--size must fit the schema" c111

c112() {
	# install --dry-run and --root never write the config's LOG (the live log of the host)
	card $A; card $B; smi_for $A:20480 $B:49140
	conf "CARDS=auto" "LOG=$CDIR/live.log" 'declare -A CARD=(' ')'
	inst --dry-run; check "dry run rc 0" eq "$RC" 0
	check "record lines printed" has "$CDIR/install.out" "record: $B 10de:2206/10de:146d VRAM 49140 MiB"
	check "dry run: live log untouched" absent "$CDIR/live.log"
	inst; check "--root rc 0" eq "$RC" 0
	check "--root: live log untouched" absent "$CDIR/live.log"
	check "--root: record written below the root" has "$ROOT/etc/geforce-bar1-resize/vram" "^$B "
}
run_case 112-install-no-live-log "install --dry-run / --root: record's log stays in the scratch dir" c112

c113() {
	# install.sh (in its own session) is SIGKILLed with all its children at its k-th install(1) or mv
	# call, for every k of a migration, then run again: the end state must equal an uninterrupted migration's
	# (2 of 3 cards in REBAR_BDFS, REBAR_N=8, a P2P key: mapped config, option file, new unit enabled, old files gone).
	# Deleting /etc/geforce-bar1-resize afterwards does not make an install enable the unit; nor does uninstall.
	card $A; card $B; card $C; smi_for $A:20480 $B:20480 $C:20480
	mkdir -p "$CDIR/stub" "$CDIR/tmp"
	ps -o pgid= -p $$ | tr -d ' ' >"$CDIR/stub/harness-pgid"
	local s k total bad="" ref
	for s in install mv; do
		# shellcheck disable=SC2016 # expanded by the stub, not here
		printf '#!/bin/sh\nn=$(cat "%s/stub/n" 2>/dev/null || echo 0); n=$((n + 1)); echo $n >"%s/stub/n"\nif [ "$n" = "$(cat "%s/stub/at" 2>/dev/null)" ]; then\n\tpg=$(ps -o pgid= -p $$ | tr -d " ")\n\t[ "$pg" = "$(cat "%s/stub/harness-pgid")" ] || kill -9 -$pg\nfi\nexec %s "$@"\n' \
			"$CDIR" "$CDIR" "$CDIR" "$CDIR" "$(type -P $s)" >"$CDIR/stub/$s"
	done
	chmod 755 "$CDIR/stub/install" "$CDIR/stub/mv"
	migr_old() {
		rm -rf "${ROOT:?}"/* "$CDIR/stub/n" "$CDIR/stub/at"; mkdir -p "$ROOT/etc/modprobe.d"
		old_install 1 "$A $B" "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
		sed -i 's/^REBAR_N=9$/REBAR_N=8/' "$ROOT/etc/rebar-arm.conf"
	}
	inst_stub() { # install.sh in its own session (setsid -w waits for it) with the stubs first in PATH
		RC=0
		# shellcheck disable=SC2046
		PATH=$CDIR/stub:$PATH TMPDIR=$CDIR/tmp env $(GBR_ENV) GBR_ROOT= GBR_STATE_DIR= GBR_MODPROBE_DIR= \
			setsid -w "$SRC/install.sh" --root "$ROOT" --yes </dev/null >"$CDIR/install.out" 2>&1 || RC=$?
	}
	end_state() {
		local f
		cat "$ROOT/etc/geforce-bar1-resize.conf" "$ROOT/$OPTF" "$ROOT/etc/systemd/system/geforce-bar1-resize.service.d/override.conf" 2>&1
		readlink "$ROOT/etc/systemd/system/sysinit.target.wants/geforce-bar1-resize.service"
		for f in migrated migrating; do [ ! -e "$ROOT/etc/geforce-bar1-resize/$f" ] || echo "marker $f"; done
		for f in $OLDS; do [ ! -e "$ROOT/$f" ] && [ ! -L "$ROOT/$f" ] || echo "left /$f"; done
	}
	migr_old; echo 0 >"$CDIR/stub/at"; inst_stub
	check "reference run rc 0" eq "$RC" 0
	total=$(cat "$CDIR/stub/n"); end_state >"$CDIR/ref"
	check "reference: 2 of 3 cards" has "$ROOT/etc/geforce-bar1-resize.conf" "^CARDS=\"$A $B\"$"
	check "reference: SIZE=8" has "$ROOT/etc/geforce-bar1-resize.conf" "^SIZE=8$"
	check "reference: P2P key" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	check "reference: enabled, migrated, nothing left" eq "$(grep -cE '^(/etc/systemd/system/geforce-bar1-resize.service|marker migrated)$' "$CDIR/ref")/$(grep -cE '^(left |marker migrating)' "$CDIR/ref")" 2/0
	check "at least 10 kill points" eq "$([ "$total" -ge 10 ] && echo yes)" yes
	for ((k = 1; k <= total; k++)); do
		migr_old; echo "$k" >"$CDIR/stub/at"; inst_stub
		echo "  kill at call $k: rc $RC" >>"$LOG"
		[ "$RC" != 0 ] && [ ! -e "$ROOT/etc/geforce-bar1-resize/migrated" ] || { bad+=" $k:not-killed($RC)"; continue; }
		rm -f "$CDIR/stub/at"; inst
		[ "$RC" = 0 ] || { bad+=" $k:rerun-rc$RC"; continue; }
		end_state >"$CDIR/end.$k"
		cmp -s "$CDIR/ref" "$CDIR/end.$k" || { bad+=" $k"; diff "$CDIR/ref" "$CDIR/end.$k" | sed "s/^/    $k: /" >>"$LOG"; }
	done
	check "killed at each of $total calls, then rerun: same end state as uninterrupted" eq "${bad# }" ""
	# a deleted state directory is not an interrupted migration
	migr_old; inst; rm "$ROOT/etc/systemd/system/sysinit.target.wants/geforce-bar1-resize.service"
	rm -rf "$ROOT/etc/geforce-bar1-resize"
	inst; check "state dir deleted: no resume" hasnt "$CDIR/install.out" "did not finish"
	check "state dir deleted: not enabled (no --enable)" absent "$ROOT/etc/systemd/system/sysinit.target.wants/geforce-bar1-resize.service"
	uninst; inst; check "fresh install after uninstall: no resume" hasnt "$CDIR/install.out" "did not finish"
	check "fresh install after uninstall: not enabled" absent "$ROOT/etc/systemd/system/sysinit.target.wants/geforce-bar1-resize.service"
}
run_case 113-migrate-interrupted "install.sh killed at every migration step: the rerun ends as an uninterrupted run; no resume from a deleted state dir" c113

c114() {
	# keys= in the config beat an adopted foreign line on the first write already; the second write is a no-op
	card $A; card $B; vram $A 20480; vram $B 20480
	conf 'declare -A CARD=(' "  [$A]=\"keys=RMDynBar1P2PEnable=1;\"" ')'
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMDynBar1P2PEnable=0;pci=$B;RMDynBar1P2PEnable=0;\"" >"$ROOT/etc/modprobe.d/p2p.conf"
	gbr driver-option --write; check "not adopted: rc 3" eq "$RC" 3
	check "shown merged line: keys= wins" has "$CDIR/out" "^options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;"
	gbr driver-option --write --adopt-driver-line; check "adopt rc 0" eq "$RC" 0
	local want="pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=1;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	check "first write: keys= wins over the adopted value" opt_is "$want"
	gbr driver-option --write; check "second write: unchanged" has "$CDIR/out" "^unchanged "
	check "second write: same line" opt_is "$want"
}
run_case 114-adopt-precedence "--adopt-driver-line: config keys= win on the first write; second write unchanged" c114

c115() {
	# batch 1 (size 16: $S2 below root 00:03.0, 0e:00.0 below root 00:04.0) succeeds, batch 2 (size 15: $S1, also
	# below 00:03.0) fails its rollback. Root 00:03.0 is unknown: $S2 must not be reported enlarged and its functions
	# stay held; root 00:04.0 is released.
	local E3=0000:0e:00.0
	card $S1 under="$U1" fail=nospc audio=1; card $S2 under="$U2" fail=nospc audio=1
	card $E3 under="0000:00:04.0 0000:10:00.0 0000:11:08.0" fail=nospc audio=1
	vram $S1 20480; vram $S2 49140; vram $E3 49140
	printf 'ok\nrollback-failed\n' >"$FAKE/layout-modes"
	conf LAYOUT=auto; boot; check "rc 0" eq "$RC" 0
	check "two batches" eq "$(lines modprobe.calls)" 2
	check "$S2 (same root as the failed batch) not reported enlarged" hasnt "$CDIR/out" "$S2 armed and resized"
	check "$S2 state unknown" has "$CDIR/out" "$S2 state unknown after the failed rollback, 0x610 left as is; reboot required$"
	check "$S2 recorded unknown" has "$CDIR/run/cards" "^$S2 0x610 unknown$"
	check "$E3 (other root) enlarged" has "$CDIR/out" "$E3 armed and resized to 65536 MiB via the layout module$"
	check "root 00:03.0 still held" eq "$(ovr $S1)/$(ovr 0000:0c:00.1)/$(ovr $S2)/$(ovr 0000:0d:00.1)" "geforce-bar1-hold/geforce-bar1-hold/geforce-bar1-hold/geforce-bar1-hold"
	check "root 00:04.0 released" eq "$(ovr $E3)/$(ovr 0000:0e:00.1)" "/"
	check "drivers_probe only for root 00:04.0" eq "$(sort "$FAKE/sys/bus/pci/drivers_probe" | tr '\n' ' ')" "0000:0e:00.0 0000:0e:00.1 "
	check "log: what stays held" has "$CDIR/out" "driver hold kept on 0000:0c:00.0 0000:0c:00.1 0000:0d:00.0 0000:0d:00.1; to release the hold by hand"
}
run_case 115-layout-partial-hold "failed batch: every card below its root ports unknown and held; other roots released" c115

c116() {
	# bound cards at 32 GiB, 0x610 armed by rebar-arm.sh this boot, old option file with only RMForceStaticBar1=0
	# groups: the migration keeps the key for both
	card $A bound=1 bar1=32768 r610=00001c81 rbbc=000ffc00; card $B bound=1 bar1=32768 r610=00001c81 rbbc=000ffc00
	smi_for $A:20480 $B:20480
	old_install 1 "$A $B" "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
	inst --dry-run; check "dry run shows both groups" has "$CDIR/install.out" "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;\""
	inst; check "rc 0" eq "$RC" 0
	check "both cards keep RMForceStaticBar1=0" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
	check "cards untouched" eq "$(count $A writes)/$(count $B writes)/$(count $A resizes)/$(count $B resizes)" 0/0/0/0
	check "still armed, 32 GiB" eq "$(reg $A 0x610) $(bar_mib $A) $(reg $B 0x610) $(bar_mib $B)" "00001c81 32768 00001c81 32768"
}
run_case 116-migrate-enlarged-only-key "bound armed 32 GiB cards, old file with only our key: kept for both, cards untouched" c116

c117() {
	# best effort: no route reaches the target, the card lists more than its BAR1: resize to the largest listed size
	card $A layout=gb rbbc=000ffc00; vram $A 65536                      # Blackwell-like: 64 GB, lists up to 32 GiB
	card $B layout=gb rbbc=000ffc00 bar1=32768; vram $B 65536           # the same card, firmware already at 32 GiB
	card $C rbbc=000ffc00; vram $C 49140                                # XVE card, route=resize, lists up to 32 GiB
	card $D v60c=00001001; vram $D 20480                                # S3 fails, lists only up to 256 MiB
	conf 'declare -A CARD=(' "  [$C]=\"route=resize\"" ')'
	boot --dry-run
	check "dry run shows the fallback" has "$CDIR/out" "$A resize to 32768 MiB, the largest size the card lists; below VRAM \(65536 MiB\)$"
	check "dry run: why" has "$CDIR/out" "$A because the card does not list 65536 MiB and the 0x610 route is not available$"
	check "dry run: would resize to 32 GiB" has "$CDIR/out" "$A would resize BAR1 to 32768 MiB \(resize only\)$"
	GBR_CONF=$ROOT/etc/geforce-bar1-resize.conf gbr check $A
	check "check: plan with the note" has "$CDIR/out" "^  PLAN    resize-only to 32768 MiB \(0x610 never written\); best effort$"
	check "check: the note" has "$CDIR/out" "^  note    resize to 32768 MiB, the largest size the card lists; below VRAM \(65536 MiB\)$"
	check "check: why" has "$CDIR/out" "^  note    because the card does not list 65536 MiB and the 0x610 route is not available$"
	check "check: a fallback is a route (rc 0)" eq "$RC" 0
	boot; check "rc 0" eq "$RC" 0
	check "$A: S1 still logged" has "$CDIR/out" "$A 10de:2206/10de:146d: S1 no VSEC"
	check "$A resized to 32 GiB" eq "$(bar_mib $A) $(count $A resizes)" "32768 1"
	check "$A success line" has "$CDIR/out" "$A resized to 32768 MiB \(resize only, 0x610 untouched\)$"
	check "$B already at the largest listed size: skip as before" has "$CDIR/out" "$B route skip: capability lists up to 32768 MiB < target 65536 MiB, and the 0x610 route is not available$"
	check "$B untouched" eq "$(bar_mib $B) $(count $B resizes)" "32768 0"
	check "route=resize, mask short: fallback" has "$CDIR/out" "$C resize to 32768 MiB, the largest size the card lists; below VRAM \(49140 MiB\)$"
	check "route=resize, mask short: why" has "$CDIR/out" "$C because the card does not list 65536 MiB and route=resize never writes 0x610$"
	check "$C 32 GiB" eq "$(bar_mib $C)" 32768
	check "nothing larger listed: skip as before" has "$CDIR/out" "$D route skip: capability lists up to 256 MiB < target 32768 MiB, and the 0x610 route is not available$"
	untouched_610 $A $B $C $D; no_vsec_write $A $B
	check "state: enlarged" has "$CDIR/run/cards" "^$A resize enlarged$"
	gbr driver-option --print
	check "fallback cards keep static BAR1 by default" has "$CDIR/out" "^no card needs the driver option$"
	conf 'declare -A CARD=(' "  [$C]=\"route=resize driver_option=on\"" "  [$A]=\"driver_option=on\"" ')'
	gbr driver-option --print
	check "driver_option=on: key for the fallback cards" has "$CDIR/out" "^options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;pci=$C;RMForceStaticBar1=0;\"$"
	card $S2 layout=gb rbbc=000ffc00
	conf "SIZE=64G" "CARDS=\"$S2\""; boot --dry-run
	check "size from config: below the configured size" has "$CDIR/out" "$S2 resize to 32768 MiB, the largest size the card lists; below the configured 65536 MiB$"
}
run_case 117-best-effort "no route to the target: resize to the largest listed size above BAR1 (note), else skip as before" c117

c118() {
	# best effort behind a switch: the layout module gets the size actually chosen (32 GiB, index 15), not the target
	card $S1 under="$U1" layout=gb rbbc=000ffc00 fail=nospc audio=1; vram $S1 65536
	GBR_CONF=/nonexistent gbr check --layout-plan $S1
	check "layout plan with the chosen size" has "$CDIR/out" "modprobe gbr_layout targets=$S1 size=15 dry_run=1"
	conf LAYOUT=auto; boot; check "rc 0" eq "$RC" 0
	check "module sized for 32 GiB" eq "$(tail -n 1 "$FAKE/modprobe.calls")" "targets=$S1 bar=1 size=15 dry_run=0"
	check "resized via the module" has "$CDIR/out" "$S1 resized to 32768 MiB via the layout module \(resize only, 0x610 untouched\)$"
	untouched_610 $S1
}
run_case 118-best-effort-layout "best effort behind a switch: the layout module plans the chosen size" c118

c119() {
	# uninstall keeps every driver key but our RMForceStaticBar1=0: an adopted line is restored as it was (a key only
	# our file had is named), otherwise the keys stay in a minimal option file, left as it is by a second uninstall
	card $A; card $B; smi_for $A:20480 $B:20480
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMDynBar1P2PEnable=0;\"" >"$ROOT/etc/modprobe.d/p2p.conf"
	cp "$ROOT/etc/modprobe.d/p2p.conf" "$CDIR/p2p.orig"
	inst --adopt-driver-line; check "adopt rc 0" eq "$RC" 0
	echo "CARD[$B]=\"keys=RmTest=1;\"" >>"$ROOT/etc/geforce-bar1-resize.conf"
	gbr driver-option --write
	check "keys= written" opt_is "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$B;RMForceStaticBar1=0;RmTest=1;"
	uninst --dry-run; check "dry run: still commented out" has "$ROOT/etc/modprobe.d/p2p.conf" "^# adopted by geforce-bar1-resize: "
	check "dry run: option file still there" present "$ROOT/$OPTF"
	uninst; check "rc 0" eq "$RC" 0
	check "adopted line restored byte for byte" eq "$(cmp -s "$CDIR/p2p.orig" "$ROOT/etc/modprobe.d/p2p.conf" && echo same)" same
	check "restore printed" has "$CDIR/uninstall.out" "^restored the NVreg_RegistryDwordsPerDevice line .* in $ROOT/etc/modprobe.d/p2p.conf$"
	check "restore: backup named" has "$CDIR/uninstall.out" "^  \(before: $ROOT/var/backups/geforce-bar1-resize/uninstall-[0-9-]+/etc/modprobe.d/p2p.conf\)$"
	check "key only in our file named" has "$CDIR/uninstall.out" "^not kept \(only in .*\):$"
	check "key only in our file: the key" has "$CDIR/uninstall.out" "^  pci=$B;RmTest=1;$"
	check "no second per-device line" absent "$ROOT/$OPTF"
	rm -rf "${ROOT:?}"/*; mkdir -p "$ROOT/etc/modprobe.d"
	inst; echo "CARD[$B]=\"keys=RmTest=1;\"" >>"$ROOT/etc/geforce-bar1-resize.conf"
	gbr driver-option --write
	uninst; check "rc 0 (no adopted line)" eq "$RC" 0
	check "minimal file: keys= kept, ours removed" opt_is "pci=$B;RmTest=1;"
	check "kept printed" has "$CDIR/uninstall.out" "^kept your driver keys in $ROOT/$OPTF \(RMForceStaticBar1=0 removed\):$"
	check "kept: the keys" has "$CDIR/uninstall.out" "^  pci=$B;RmTest=1;$"
	check "first uninstall: driver option note" has "$CDIR/uninstall.out" "RMForceStaticBar1=0 stays active"
	uninst; check "second uninstall: left as it is" has "$CDIR/uninstall.out" "^kept $ROOT/$OPTF as it is"
	check "second uninstall: no driver option note" hasnt "$CDIR/uninstall.out" "RMForceStaticBar1=0 stays active"
	check "second uninstall: same line" opt_is "pci=$B;RmTest=1;"
	inst; check "reinstall keeps the keys" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RmTest=1;"
}
run_case 119-uninstall-driver-keys "uninstall: an adopted line is restored, other keys stay in a minimal option file" c119

c120() {
	# not root: plan, boot, driver-option, check and install.sh (also --dry-run) stop with exit 2, not with a plan in
	# which no card has a Resizable BAR capability
	card $A; smi_for $A:20480
	mkdir -p "$CDIR/stub"
	# shellcheck disable=SC2016 # $1 and $@ belong to the stub
	printf '#!/bin/sh\n[ "$1" = -u ] && { echo 1000; exit 0; }\nexec %s "$@"\n' "$REAL_ID" >"$CDIR/stub/id"
	chmod 755 "$CDIR/stub/id"
	local s rc
	for s in plan "boot --dry-run" "driver-option --print" "check $A"; do
		rc=0
		# shellcheck disable=SC2046 # word list of assignments
		PATH=$CDIR/stub:$PATH env $(GBR_ENV) "$SRC/scripts/geforce-bar1-resize" $s >"$CDIR/out" 2>&1 || rc=$?
		check "$s: rc 2" eq "$rc" 2
		check "$s: says why" has "$CDIR/out" "^${s%% *}: run as root \(setpci cannot read extended config space otherwise\)$"
	done
	rc=0; PATH=$CDIR/stub:$PATH "$SRC/install.sh" --root "$ROOT" --dry-run </dev/null >"$CDIR/install.out" 2>&1 || rc=$?
	check "install --dry-run: rc 2" eq "$rc" 2
	check "install: says why" has "$CDIR/install.out" "^install: run as root \(setpci cannot read extended config space otherwise\)$"
	check "install: no plan" hasnt "$CDIR/install.out" "^Plan"
	check "nothing written" eq "$(find "$ROOT" -type f | wc -l)" 0
}
run_case 120-not-root "not root: plan, boot, driver-option, check and install.sh --dry-run stop with exit 2" c120

c121() {
	# RMForceStaticBar1=0 by default only for 0x610 cards: a resize-only card keeps static BAR1 (P2P setups need it)
	# unless driver_option=on; DRIVER_OPTION=on also covers a card the firmware already made large enough
	card $A; card $C layout=plain rbbc=000ffc00; card $D layout=plain bar1=32768 rbbc=000ffc00
	vram $A 20480; vram $C 20480; vram $D 20480
	gbr driver-option --print; check "default: only the 0x610 card" has "$CDIR/out" "^options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;\"$"
	GBR_CONF=/nonexistent gbr check $A $C
	check "check: 0x610 card gets the key" has "$CDIR/out" "^  driver  RMForceStaticBar1=0 \(0x610 route"
	check "check: resize-only card keeps static BAR1" has "$CDIR/out" "^  driver  static BAR1 kept, no RMForceStaticBar1=0 \(resize only; driver_option=on adds it\)$"
	boot; check "boot rc 0" eq "$RC" 0
	check "$C resized without 0x610" has "$CDIR/run/cards" "^$C resize enlarged$"
	gbr driver-option --write; check "after the boot: still only the 0x610 card" opt_is "pci=$A;RMForceStaticBar1=0;"
	conf 'declare -A CARD=(' "  [$C]=\"driver_option=on\"" ')'
	gbr driver-option --write; check "driver_option=on for the resize-only card" opt_is "pci=$A;RMForceStaticBar1=0;pci=$C;RMForceStaticBar1=0;"
	conf DRIVER_OPTION=on
	gbr driver-option --write; check "DRIVER_OPTION=on: also the card the firmware sized" opt_is "pci=$A;RMForceStaticBar1=0;pci=$C;RMForceStaticBar1=0;pci=$D;RMForceStaticBar1=0;"
	conf ""
	gbr driver-option --write; check "back to auto: the card resized without 0x610 this boot drops it; one already listed keeps it" opt_is "pci=$A;RMForceStaticBar1=0;pci=$D;RMForceStaticBar1=0;"
	rm -rf "${ROOT:?}"/*; mkdir -p "$ROOT/etc/modprobe.d"
	inst; check "fresh config: DRIVER_OPTION=auto" has "$ROOT/etc/geforce-bar1-resize.conf" "^DRIVER_OPTION=auto$"
	inst --driver-option on; check "--driver-option on" has "$ROOT/etc/geforce-bar1-resize.conf" "^DRIVER_OPTION=on$"
	inst --driver-option sideways; check "--driver-option sideways: refused" eq "$RC" 1
}
run_case 121-driver-option-routes "RMForceStaticBar1=0 by default only through 0x610; driver_option=on adds resize-only cards" c121

c122() {
	# a PF with 4 SR-IOV virtual functions (physfn link, class 0302, no ReBAR): the VFs are skipped without a line
	card $A; vram $A 20480
	local pf=$FAKE/sys/devices/pci0000:00/$A v vf
	for v in 4 5 6 7; do
		vf=$FAKE/sys/devices/pci0000:00/0000:05:00.$v
		mkdir -p "$vf" && ln -s "$vf" "$FAKE/sys/bus/pci/devices/0000:05:00.$v" && ln -s "$pf" "$vf/physfn"
		echo 0x10de >"$vf/vendor"; echo 0x2236 >"$vf/device"; echo 0x030200 >"$vf/class"
		echo 0x10de >"$vf/subsystem_vendor"; echo 0x1482 >"$vf/subsystem_device"; echo "(null)" >"$vf/driver_override"
	done
	boot; check "rc 0" eq "$RC" 0; large $A
	check "no line for the VFs" hasnt "$CDIR/out" "0000:05:00\.[4-7]"
	check "no pre-Turing hint" hasnt "$CDIR/out" "pre-Turing"
	GBR_CONF=/nonexistent gbr check
	check "check: rc 0 (VFs not listed)" eq "$RC" 0
	check "check: no VF section" hasnt "$CDIR/out" "== 0000:05:00\.[4-7]"
	GBR_CONF=/nonexistent gbr check 0000:05:00.4
	check "check of a VF by address: named as one" has "$CDIR/out" "not a candidate: SR-IOV virtual function of $A, never resized$"
	gbr driver-option --print; check "driver option: the PF only" has "$CDIR/out" "^options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;\"$"
}
run_case 122-sriov-vfs "SR-IOV virtual functions are skipped quietly; a VF named explicitly is reported as one" c122

c100() {
	card $A; vram $A 20480
	conf "SIZE=8" "LOG=$CDIR/new.log"
	oldconf "REBAR_BDFS=\"$A\"" "REBAR_N=10" "REBAR_LOG=$CDIR/old.log"
	gbr boot --dry-run
	check "both files: the new one is used" has "$CDIR/out" "config $ROOT/etc/geforce-bar1-resize.conf$"
	check "both files: new SIZE" has "$CDIR/out" "$A would arm 0x610 VAL=8 "
	check "both files: no deprecated key" hasnt "$CDIR/out" "deprecated key"
	rm "$ROOT/etc/geforce-bar1-resize.conf"
	gbr boot --dry-run
	check "only the old file: read" has "$CDIR/out" "config $ROOT/etc/rebar-arm.conf$"
	check "only the old file: REBAR_N mapped" has "$CDIR/out" "deprecated key REBAR_N=10; use SIZE=10$"
	check "only the old file: VAL 10" has "$CDIR/out" "$A would arm 0x610 VAL=10 "
	check "REBAR_LOG mapped" has "$CDIR/out" "deprecated key REBAR_LOG=$CDIR/old.log; use LOG=$CDIR/old.log$"
	GBR_CONF=/nonexistent gbr boot --dry-run
	check "GBR_CONF missing: the old file is not used" hasnt "$CDIR/out" "deprecated key|config "
	check "GBR_CONF missing: defaults (record)" has "$CDIR/out" "$A would arm 0x610 VAL=9 "
	conf "CARDS=auto" "SIZE=8" "REBAR_BDFS=\"0000:99:00.0\"" "REBAR_N=10" "REBAR_LAYOUT=auto" "LOG=$CDIR/new.log"
	gbr boot --dry-run
	check "new keys beat REBAR_* in one file" has "$CDIR/out" "$A would arm 0x610 VAL=8 "
	check "REBAR_BDFS ignored when CARDS is set" hasnt "$CDIR/out" "REBAR_BDFS|0000:99:00.0"
	check "REBAR_LAYOUT mapped" has "$CDIR/out" "deprecated key REBAR_LAYOUT=auto; use LAYOUT=auto$"
	conf "REBAR_ARM=sideways" "LOG=$CDIR/new.log"; gbr boot --dry-run
	check "unknown REBAR_ARM -> skip" has "$CDIR/out" "deprecated key REBAR_ARM=sideways; use ROUTE=skip$"
	check "unknown REBAR_ARM: card skipped" has "$CDIR/out" "$A route skip: route=skip in config$"
	rm "$ROOT/etc/geforce-bar1-resize.conf"
	oldconf "REBAR_BDFS=\"$C\"" "REBAR_LOG=$CDIR/old.log"
	gbr boot; check "old-only boot logs to REBAR_LOG" has "$CDIR/old.log" "$C absent, skip$"
	check "old-only boot warns about old files" has "$CDIR/out" "old 3080-20gb-rebar files still present: $ROOT/etc/rebar-arm.conf"
}
run_case 100-config-files "new config beats /etc/rebar-arm.conf; old file alone mapped; GBR_CONF; REBAR_LOG/LAYOUT/ARM" c100

# --- driver option --------------------------------------------------------------------------------------------------
c101() {
	card $A; card $B; card $S1; card $C bar1=32768 rbbc=000ffc00
	for b in $A $B $S1 $C; do vram $b 20480; done
	conf "EXCLUDE=\"$B\""
	printf '%s\n' "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=0C:00.0;RMDynBar1P2PEnable=0;pci=$C;RMDynBar1P2PEnable=0;RmFoo=0x1;\"" >"$ROOT/$OPTF"
	gbr driver-option --write; check "rc 0" eq "$RC" 0
	check "merged" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMDynBar1P2PEnable=0;pci=$S1;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$C;RMDynBar1P2PEnable=0;RmFoo=0x1;"
	cp "$ROOT/$OPTF" "$CDIR/opt.1"
	gbr driver-option --write; check "second write unchanged" eq "$(cmp -s "$CDIR/opt.1" "$ROOT/$OPTF" && echo same)" same
	echo "# options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMDynBar1P2PEnable=0;\"" >"$ROOT/etc/modprobe.d/old-p2p.conf"
	gbr driver-option --write; check "commented-out foreign line: not foreign" eq "$RC" 0
	check "commented-out line: no keys taken" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMDynBar1P2PEnable=0;pci=$S1;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$C;RMDynBar1P2PEnable=0;RmFoo=0x1;"
}
run_case 101-driver-option-merge "excluded or not-enlarged cards keep their keys without ours; short/upper-case pci= merged" c101

c102() {
	card $A; card $B; smi_for $A:20480 $B:20480
	inst --enable; check "rc 0" eq "$RC" 0
	sed -i "s|pci=$B;RMForceStaticBar1=0;|pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;|" "$ROOT/$OPTF"
	inst; check "reinstall rc 0" eq "$RC" 0
	check "reinstall keeps the hand-added P2P opt-out" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	gbr record; check "record keeps it" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	mkdir -p "$ROOT/usr/lib/modprobe.d"
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMDynBar1P2PEnable=0;\"" >"$ROOT/usr/lib/modprobe.d/vendor.conf"
	inst; check "foreign line in /usr/lib/modprobe.d stops the install" eq "$RC" 1
	check "named" has "$CDIR/install.out" "usr/lib/modprobe.d/vendor.conf"
	check "option file untouched" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
}
run_case 102-install-keeps-keys "install rerun and record keep a hand-added key; a foreign line in /usr/lib/modprobe.d stops install" c102

c69() {
	# a card swapped in with other ids (route none) at an address the option file lists: record notes the swap in
	# $STATE/replaced, so a rewrite that does not complete in that run (a foreign line, rc 3) does not let a later
	# write in another process give the new card the old card's key; the first write that completes removes the note
	local note=$ROOT/etc/geforce-bar1-resize/replaced
	card $A bound=1 layout=plain bar1=32768 rbbc=000ffc00 id=10de:2b85 sub=10de:2000
	vram $A 20480 10de:2206/10de:146d
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;\"" >"$ROOT/$OPTF"
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMDynBar1P2PEnable=0;\"" >"$ROOT/etc/modprobe.d/p2p.conf"
	printf '00000000:05:00.0, 32607, 615.71.09\n' >"$FAKE/smi"
	conf ""
	gbr record $A; check "record: rc 0, new card recorded" eq "$RC/$(grep -c "^$A 10de:2b85/10de:2000 32607 " "$ROOT/etc/geforce-bar1-resize/vram")" 0/1
	check "record: its rewrite did not complete (foreign line)" has "$CDIR/out" "record: driver-option --write did not complete"
	check "record: swap noted with the old ids" has "$note" "^$A 10de:2206/10de:146d$"
	check "record: option file untouched" opt_is "pci=$A;RMForceStaticBar1=0;"
	gbr driver-option --print; check "print: no RMForceStaticBar1=0 for the new card" hasnt "$CDIR/out" "pci=$A;RMForceStaticBar1=0;"
	check "print: note kept" present "$note"
	gbr driver-option --write --adopt-driver-line; check "later write: rc 0" eq "$RC" 0
	check "later write: the new card does not inherit the key; the adopted key stays" opt_is "pci=$A;RMDynBar1P2PEnable=0;"
	check "later write: note removed" absent "$note"
	gbr driver-option --write; check "next write: still no key" opt_is "pci=$A;RMDynBar1P2PEnable=0;"
	# the old card comes back before any write completed: its listing is its own again
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;\"" >"$ROOT/$OPTF"
	echo "$A 10de:2206/10de:146d" >"$note"
	card $A bound=1 layout=plain bar1=32768 rbbc=000ffc00
	sed -i "/^$A /d" "$ROOT/etc/geforce-bar1-resize/vram"; vram $A 20480
	gbr driver-option --write; check "old card back: keeps its key" opt_is "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
}
run_case 69-swap-note-rewrite "a swap noted by record survives a rewrite that fails; the next write drops the old key, then the note" c69

c79() {
	# install.sh after a swap, before the record unit recorded the new card: its own record (scratch) and its write
	# (another process) still drop the old card's key; --dry-run prints the same and changes nothing
	local note=$ROOT/etc/geforce-bar1-resize/replaced
	card $A bound=1 layout=plain bar1=32768 rbbc=000ffc00 id=10de:2b85 sub=10de:2000
	card $B bound=1 layout=plain bar1=32768 rbbc=000ffc00
	vram $A 20480 10de:2206/10de:146d; vram $B 20480
	smi_for $A:32607 $B:20480
	mkdir -p "$ROOT/etc/modprobe.d"
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;\"" >"$ROOT/$OPTF"
	inst --dry-run; check "dry run: rc 0" eq "$RC" 0
	check "dry run: the file it would write keeps $B only" has "$CDIR/install.out" "^  options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$B;RMForceStaticBar1=0;\"$"
	check "dry run: no note written" absent "$note"
	check "dry run: option file untouched" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
	inst; check "install: rc 0" eq "$RC" 0
	check "install: swap logged" has "$CDIR/install.out" "$A held 10de:2206/10de:146d before: card swapped"
	check "install: new card recorded" has "$ROOT/etc/geforce-bar1-resize/vram" "^$A 10de:2b85/10de:2000 32607 "
	check "install: $A loses the old card's key, $B (same card) keeps it" opt_is "pci=$B;RMForceStaticBar1=0;"
	check "install: note removed by its write" absent "$note"
	gbr record $A; check "record unit afterwards: already recorded" has "$CDIR/out" "$A 10de:2b85/10de:2000 VRAM 32607 MiB already recorded"
	gbr driver-option --write; check "later write: unchanged" opt_is "pci=$B;RMForceStaticBar1=0;"
}
run_case 79-swap-note-install "install.sh after a swap, before the record unit: its record and its write drop the old key" c79

# --- console --------------------------------------------------------------------------------------------------------
c103() {
	card $A; card $B; card $C class=0x030200; card $D class=0x030200
	for b in $A $B $C $D; do vram $b 20480; done
	local g
	for g in "1:$A" "2:$B"; do mkdir -p "$FAKE/sys/class/graphics/fb${g%%:*}"; ln -s "$(sysdir "${g#*:}")" "$FAKE/sys/class/graphics/fb${g%%:*}/device"; done
	local s3
	read -r s3 _ < <(sed -n 4p "$(sysdir $D)/resource")
	printf '%x-%x : %s\n' "$s3" $((s3 + 0xfffff)) simplefb >>"$FAKE/proc/iomem"
	conf "CONSOLE=skip" 'declare -A CARD=(' "  [$B]=\"console=include\"" ')'
	boot; check "rc 0" eq "$RC" 0
	check "fb device link only: console, skipped" has "$CDIR/out" "$A route skip: console card \(console=skip\)$"
	stock $A
	check "per-card console=include beats CONSOLE=skip" has "$CDIR/out" "$B console card: the kernel removes the firmware framebuffer \(none found in its BARs\)"
	large $B
	check "0302 without fb, CONSOLE=skip: not a console, enlarged" hasnt "$CDIR/out" "$C route skip"
	large $C
	check "0302 with a framebuffer in BAR3: skipped" has "$CDIR/out" "$D route skip: firmware framebuffer \(simplefb@BAR3\) inside BAR3 of a non-VGA function; the kernel would not remove it$"
	stock $D
}
run_case 103-console-more "fb link only (CONSOLE=skip), per-card console=include, 0302 without fb, 0302 fb in BAR3" c103

# --- migration ------------------------------------------------------------------------------------------------------
c104() {
	# enlarged this boot by rebar-arm.sh, driver bound: the migration must keep RMForceStaticBar1=0 for them
	card $A bound=1 bar1=32768 r610=00001c81 rbbc=000ffc00; card $B bound=1 bar1=32768 r610=00001c81 rbbc=000ffc00
	card $C bound=1 layout=plain bar1=32768 rbbc=000ffc00
	smi_for $A:20480 $B:20480 $C:20480
	old_install 1 "$A $B $C" "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$C;RMForceStaticBar1=0;"
	inst; check "rc 0" eq "$RC" 0
	local want="pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$C;RMForceStaticBar1=0;"
	check "live enlarged cards keep RMForceStaticBar1=0" opt_is "$want"
	check "plan: bound cards planned as the next boot" has "$CDIR/install.out" "$A bound to nvidia now; planned as the next boot"
	inst; check "second install rc 0" eq "$RC" 0
	check "second install keeps it" opt_is "$want"
	gbr record; check "record keeps it" opt_is "$want"
	gbr driver-option --write; check "driver-option --write keeps it" opt_is "$want"
	check "nothing written to the cards" eq "$(count $A writes)/$(count $B writes)/$(count $C writes)" 0/0/0
}
run_case 104-migrate-live "migration on a host enlarged this boot (0x610 and resize-only): RMForceStaticBar1=0 kept" c104

c105() {
	card $A; card $B; smi_for $A:20480 $B:20480
	old_install 1 "$A" "pci=$A;RMForceStaticBar1=0;pci=$B;RMDynBar1P2PEnable=0;"
	printf '%s\n' "REBAR_BDFS=\"$A\"" "REBAR_N=10" "REBAR_ARM=none" "REBAR_LAYOUT=auto" >"$ROOT/etc/rebar-arm.conf"
	inst; check "rc 0" eq "$RC" 0
	check "REBAR_N=10 -> SIZE=10" has "$ROOT/etc/geforce-bar1-resize.conf" "^SIZE=10$"
	check "REBAR_ARM=none -> ROUTE=resize" has "$ROOT/etc/geforce-bar1-resize.conf" "^ROUTE=resize$"
	check "REBAR_LAYOUT=auto -> LAYOUT=auto" has "$ROOT/etc/geforce-bar1-resize.conf" "^LAYOUT=auto$"
	check "option group of a card outside REBAR_BDFS kept as keys=" has "$ROOT/etc/geforce-bar1-resize.conf" "\[$B\]=\"ids=10de:2206/10de:146d keys=RMDynBar1P2PEnable=0;\""
	# ROUTE=resize with SIZE=10: $A has no route (its mask stops at 256 MiB), so it gets no RMForceStaticBar1=0
	check "option file: P2P key of $B kept, no RMForceStaticBar1=0 for the unroutable $A" opt_is "pci=$B;RMDynBar1P2PEnable=0;"
	check "config parses" eq "$(bash -n "$ROOT/etc/geforce-bar1-resize.conf" && echo ok)" ok
	gbr boot; check "route resize from the migrated config" has "$CDIR/out" "$A route skip: ReBAR capability does not advertise 65536 MiB"
	untouched_610 $A $B
}
run_case 105-migrate-mapping "migration maps REBAR_N/ARM=none/LAYOUT; keys of a card outside REBAR_BDFS kept" c105

c106() {
	card $A; smi_for $A:20480
	conf "CARDS=auto" "SIZE=8"
	old_install 1 "$A" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	inst; check "rc 0" eq "$RC" 0
	check "existing config: old one not mapped" has "$CDIR/install.out" "note: /etc/geforce-bar1-resize.conf exists; /etc/rebar-arm.conf is not mapped into it"
	check "existing SIZE kept" has "$ROOT/etc/geforce-bar1-resize.conf" "^SIZE=8$"
	check "old files moved anyway" absent "$ROOT/etc/rebar-arm.conf"
	check "P2P key kept (config without a CARD block)" opt_is "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	check "keys written into the config as CARD[]" has "$ROOT/etc/geforce-bar1-resize.conf" "^CARD\[$A\]=\"ids=10de:2206/10de:146d keys=RMDynBar1P2PEnable=0;\"$"
	inst --size 16G; check "--size on a config without a CARD block" has "$ROOT/etc/geforce-bar1-resize.conf" "^SIZE=16G$"
	inst --exclude 10de:2684; check "--exclude on a config without EXCLUDE" has "$ROOT/etc/geforce-bar1-resize.conf" "^EXCLUDE=10de:2684$"
	gbr boot --dry-run; check "the script reads both" has "$CDIR/out" "$A would arm 0x610 VAL=8 "
	gbr driver-option --print; check "keys= from the appended CARD[] line" has "$CDIR/out" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
}
run_case 106-migrate-existing-config "existing hand-written config (no CARD block): kept, P2P key and new flags still land" c106

c107() {
	card $A; smi_for $A:20480
	old_install 1 "$A" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	snap >"$CDIR/tree.0"
	inst --dry-run; check "dry run rc 0" eq "$RC" 0
	snap >"$CDIR/tree.1"
	check "migration dry run: nothing changed" same_tree "$CDIR/tree.0" "$CDIR/tree.1"
	check "says what it would move" has "$CDIR/install.out" "would be moved $ROOT/etc/rebar-arm.conf"
	inst; tree_sum "$ROOT" >"$CDIR/root.1"
	uninst --dry-run; tree_sum "$ROOT" >"$CDIR/root.2"
	check "uninstall dry run: nothing changed" same_tree "$CDIR/root.1" "$CDIR/root.2"
	echo "options nvidia NVreg_RegistryDwords=\"RmFoo=1;\"" >"$ROOT/etc/modprobe.d/user.conf"
	uninst; check "rc 0" eq "$RC" 0
	check "user's modprobe.d file kept" present "$ROOT/etc/modprobe.d/user.conf"
	check "migrated P2P key kept in a minimal option file" opt_is "pci=$A;RMDynBar1P2PEnable=0;"
	check "kept printed" has "$CDIR/uninstall.out" "^kept your driver keys in $ROOT/$OPTF \(RMForceStaticBar1=0 removed\):$"
	check "kept: the keys" has "$CDIR/uninstall.out" "^  pci=$A;RMDynBar1P2PEnable=0;$"
	check "migration backup kept" eq "$(find "$ROOT/var/backups/geforce-bar1-resize" -type d -name migrated-from-rebar-arm | wc -l)" 1
	check "no enable link left" eq "$(find "$ROOT/etc/systemd/system" -path '*wants*' \( -name 'geforce-bar1-resize*' -o -name 'rebar-arm*' \) | wc -l)" 0
	tree_sum "$ROOT" >"$CDIR/root.3"
	uninst; check "second uninstall rc 0" eq "$RC" 0
	tree_sum "$ROOT" >"$CDIR/root.4"
	check "second uninstall: nothing removed" eq "$(grep -v '^\./var/backups/' "$CDIR/root.3" | md5sum)" "$(grep -v '^\./var/backups/' "$CDIR/root.4" | md5sum)"
	check "no config write" eq "$(count $A writes)" 0
}
run_case 107-dryrun-uninstall "migration --dry-run and uninstall --dry-run change nothing; uninstall keeps user files, idempotent" c107

c108() {
	# a card behind a switch and bound cards: install --layout auto still plans them
	card $A bound=1; card $S1 under="$U1" bound=1; smi_for $A:20480 $S1:20480
	inst --layout auto; check "rc 0" eq "$RC" 0
	check "plan: would arm $A" has "$CDIR/install.out" "$A would arm 0x610 VAL=9"
	check "plan: would arm $S1" has "$CDIR/install.out" "$S1 would arm 0x610 VAL=9"
	check "layout module wanted" has "$CDIR/install.out" "Layout module gbr_layout"
	gbr plan; check "plan: bound note" has "$CDIR/out" "$S1 bound to nvidia now; planned as the next boot, before the driver binds$"
}
run_case 108-install-bound-switch "install --layout auto with bound cards behind a switch: plan and module" c108
