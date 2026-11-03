# shellcheck shell=bash disable=SC2154,SC2034,SC2086 # run.sh sets the variables; card addresses never need quoting
# SPDX-License-Identifier: MIT
# Boot, check, repair, record, driver option and layout module cases for tests/run.sh (sourced). Each case is a
# function run through run_case.

# --- discovery, sizing, routes (boot) -------------------------------------------------------------------------------
c01() {
	card $A; vram $A 20480
	boot; check "rc 0" eq "$RC" 0; large $A
	check "log: version first" has "$CDIR/out" "^[^ ]+ geforce-bar1-resize 0\.2 sha256 [0-9a-f]{12}"
	check "log: head line, verified" has "$CDIR/out" "$A 10de:2206/10de:146d \(verified\) VRAM 20480 MiB \(record\), target 32768 MiB, BAR1 256 MiB$"
	check "log: route" has "$CDIR/out" "$A route 0x610 VAL=9: arm, then resize to 32768 MiB$"
	check "log: armed and resized" has "$CDIR/out" "$A armed and resized to 32768 MiB$"
	check "state: enlarged" has "$CDIR/run/cards" "^$A 0x610 enlarged$"
	boot; check "rerun: skip" has "$CDIR/out" "$A already armed and resized \(32768 MiB\), skip$"
	check "rerun: no new write or resize" eq "$(count $A writes)/$(count $A resizes)" 1/1
	check "rerun: state kept" has "$CDIR/run/cards" "^$A 0x610 enlarged$"
}
run_case 01-auto-one "CARDS=auto, VRAM from the record: armed n=9, rerun no-op" c01

c02() {
	card $A; card $B id=10de:2684 sub=1458:4105; card $C id=10de:2204 sub=10de:1454
	vram $A 20480; vram $B 49140; vram $C 12288
	boot; check "rc 0" eq "$RC" 0; large $A
	check "$B 64 GiB (n 10)" eq "$(reg $B 0x610) $(bar_mib $B)" "00001d01 65536"
	check "$C 16 GiB (n 8)" eq "$(reg $C 0x610) $(bar_mib $C)" "00001c01 16384"
	check "$B untested label" has "$CDIR/out" "$B 10de:2684/1458:4105 \(untested\) VRAM 49140 MiB \(record\), target 65536 MiB"
	check "largest target first" before "$CDIR/out" "$B armed and resized" "$A route 0x610"
	check "then by size: $A before $C" before "$CDIR/out" "$A armed and resized" "$C route 0x610"
}
run_case 02-auto-mixed-sizes "3 cards, 20/48/12 GB: n 9/10/8, largest first, untested labels" c02

c03() {
	card $A; card $B
	boot; check "rc 0" eq "$RC" 0; stock $A $B
	check "log: VRAM unknown" has "$CDIR/out" "$A route skip: VRAM unknown \(driver never seen this card\); recorded when the driver loads, enlarged next boot$"
	vram $B 20480 10de:2206/10de:9999
	boot; check "stale ids: logged" has "$CDIR/out" "$B VRAM record is for 10de:2206/10de:9999, the card is 10de:2206/10de:146d; record ignored$"
	stock $B
}
run_case 03-vram-unknown "no record: skipped with the reason; a record with other ids is ignored" c03

c04() {
	card $A; card $B; card $C
	conf "SIZE=32G" "EXCLUDE=\"$B\"" 'declare -A CARD=(' "  [$C]=\"ids=10de:2206/10de:146d size=8\"" ')'
	boot; check "rc 0" eq "$RC" 0; large $A; stock $B
	check "log: size from config" has "$CDIR/out" "$A 10de:2206/10de:146d \(verified\) size from config, target 32768 MiB, BAR1 256 MiB$"
	check "log: excluded" has "$CDIR/out" "$B 10de:2206/10de:146d: not a candidate: excluded by config$"
	check "$C per-card size 8 (16 GiB)" eq "$(reg $C 0x610) $(bar_mib $C)" "00001c01 16384"
	check "$C label untested (n 8)" has "$CDIR/out" "$C 10de:2206/10de:146d \(untested\) size from config, target 16384 MiB"
}
run_case 04-config-size-exclude "SIZE=32G, EXCLUDE a BDF, per-card size by BDF with ids" c04

c05() {
	card $A; card $B id=10de:2684 sub=1458:4105
	vram $A 20480; vram $B 24564
	conf 'declare -A CARD=(' "  [$A]=\"ids=10de:2204 size=10\"" '  [10de:2684/1458:4105]="route=skip"' '  [10de:2206]="size=8 bogus=1 layout=sideways"' ')'
	boot; check "rc 0" eq "$RC" 0
	check "BDF entry with other ids ignored" has "$CDIR/out" "$A CARD\[$A\] ids=10de:2204 differ from the card at $A \(10de:2206/10de:146d\); entry ignored$"
	check "id fallback: size 8" eq "$(bar_mib $A)" 16384
	check "unknown key logged" has "$CDIR/out" "$A CARD\[10de:2206\]: unknown key bogus; ignored$"
	check "invalid value logged" has "$CDIR/out" "$A CARD\[10de:2206\]: layout=sideways invalid"
	check "id/subsys entry: skip" has "$CDIR/out" "$B route skip: route=skip in config$"
	stock $B
}
run_case 05-card-overrides "CARD[]: BDF entry with wrong ids falls back to id; id/subsys route=skip; bad keys logged" c05

c06() {
	card $E; vram $E 20480
	conf "CARDS=\"01:00.0 $E\""
	boot; check "short form = domain 0000: absent" has "$CDIR/out" "0000:01:00.0 absent, skip$"
	large $E
}
run_case 06-domain-0001 "explicit CARDS: short address means domain 0000; 0001:01:00.0 works" c06

c07() {
	card $A bound=1; card $B; card $C class=0x040300; vram $A 20480; vram $B 20480
	boot; check "bound skipped" has "$CDIR/out" "$A already bound to nvidia, skip$"
	stock $A; large $B
	check "audio class never listed in auto" hasnt "$CDIR/out" "$C"
	conf "CARDS=\"$C\""; boot
	check "explicit audio: not a display controller" has "$CDIR/out" "$C 10de:2206/10de:146d: not a candidate: class 0x040300 is not a display controller \(0300 or 0302\)$"
}
run_case 07-bound-audio "bound card reported, not touched; audio never a candidate" c07

c08() {
	card $A layout=gb; card $B layout=gb rbbc=000ffc00; vram $A 20480; vram $B 20480
	boot; check "rc 0" eq "$RC" 0
	check "S1 logged for $A" has "$CDIR/out" "$A 10de:2206/10de:146d: S1 no VSEC \(ID 000b v1\) at 0x600 in the capability chain$"
	check "S1: no 0x610 route for $A" has "$CDIR/out" "$A 0x610 route not available$"
	check "$A skip" has "$CDIR/out" "$A route skip: capability lists up to 256 MiB < target 32768 MiB, and the 0x610 route is not available$"
	no_vsec_write $A $B
	check "$B resize-only (0x19c)" has "$CDIR/out" "$B resized to 32768 MiB \(resize only, 0x610 untouched\)$"
	check "$B 32 GiB" eq "$(bar_mib $B)" 32768
	untouched_610 $A $B
}
run_case 08-gb-layout "Blackwell-like layout (ReBAR at 0x190, no VSEC): never written; native 32G resized" c08

c09() {
	card $A v604=02410002; card $B v60c=00001001; card $C r610=00001101; card $D hdr=81
	for b in $A $B $C $D; do vram $b 20480; done
	boot; check "rc 0" eq "$RC" 0
	check "S2" has "$CDIR/out" "$A 10de:2206/10de:146d: S2 VSEC header at 0x604 reads 02410002, not ID 0001 rev 1 len 024$"
	check "S3" has "$CDIR/out" "$B 10de:2206/10de:146d: S3 0x60c reads 00001001: FB_SIZE_OVERRIDE not supported or reserved bits set$"
	check "S4" has "$CDIR/out" "$C 10de:2206/10de:146d: S4 0x610 reads 00001101: reserved bits set or an unknown stock value$"
	check "S6" has "$CDIR/out" "$D 10de:2206/10de:146d: S6 not a type 0 endpoint \(header type 81\)$"
	untouched_610 $A $B $C $D
	check "S2: 0x610 never read" hasnt "$CDIR/out" "0x610 reads.*$A"
}
run_case 09-sfail "S2/S3/S4/S6 failures: no 0x610 write, first failed check logged" c09

c10() {
	card $A layout=plain; vram $A 20480
	boot; check "S1 fails on a plain layout" has "$CDIR/out" "$A .*S1 no VSEC"
	untouched_610 $A
	card $B; vram $B 20480; echo 00000000 >"$FAKE/cfg/$B/0xbb0"; echo 00000000 >"$FAKE/cfg/$B/0x900"
	echo 30010001 >"$FAKE/cfg/$B/0x100"; echo 9001000b >"$FAKE/cfg/$B/0x600"; echo c0010019 >"$FAKE/cfg/$B/0x900"
	for r in 0xbb0 0xbb4 0xbb8 0xbbc 0xbc0 0xbc4 0xbc8; do rm -f "$FAKE/cfg/$B/$r"; done
	echo 60010015 >"$FAKE/cfg/$B/0x300"; echo 00000100 >"$FAKE/cfg/$B/0x304"; echo 00000460 >"$FAKE/cfg/$B/0x308"
	echo 00001c00 >"$FAKE/cfg/$B/0x30c"; echo 00000801 >"$FAKE/cfg/$B/0x310"; echo 00000200 >"$FAKE/cfg/$B/0x314"; echo 00000503 >"$FAKE/cfg/$B/0x318"
	echo 0x30c >"$FAKE/cfg/$B/capreg"; echo 0x310 >"$FAKE/cfg/$B/ctlreg"
	conf "CARDS=\"$B\""; boot
	check "S5: ReBAR elsewhere" has "$CDIR/out" "$B 10de:2206/10de:146d: S5 ReBAR capability at 0x300, BAR1 entry at 0x30c: not the XVE layout \(0xbb0, 0xbbc\)$"
	check "S5: no 0x610 route" has "$CDIR/out" "$B 0x610 route not available$"
	untouched_610 $B
	conf "CARDS=\"$A $B\"" 'ROUTE=0x610!'; boot --dry-run
	check "global ROUTE=0x610! waives S5 too" has "$CDIR/out" "$B would arm 0x610 VAL=9 and resize BAR1 to 32768 MiB \(forced: S5 waived\)$"
	check "global ROUTE=0x610!: S1 still refuses" has "$CDIR/out" "$A route skip: .*the 0x610 route is not available$"
	conf "CARDS=\"$B\"" 'ROUTE=0x611'; boot --dry-run
	check "invalid ROUTE: note lists 0x610!" has "$CDIR/out" "ROUTE=0x611 invalid \(auto, resize, 0x610, 0x610!, skip\); using auto$"
	conf "CARDS=\"$B\"" 'declare -A CARD=(' "  [$B]=\"route=0x610!\"" ')'; boot
	check "0x610! waives S5: forced" has "$CDIR/out" "$B route 0x610 VAL=9: arm, then resize to 32768 MiB \(forced: S5 waived\)$"
	check "forced: resized" eq "$(bar_mib $B)" 32768
	# another VSEC earlier in the chain (0x100 -> 0x600): S1 looks at what the walk reaches at 0x600
	card $C; vram $C 20480; echo 6001000b >"$FAKE/cfg/$C/0x100"
	conf "CARDS=\"$C\""; boot
	check "extra VSEC before 0x600: 0x610 route" has "$CDIR/out" "$C armed and resized to 32768 MiB$"
	# the GA102 bytes at 0x600 but no header links to them (0x100 -> 0x900)
	card $D; vram $D 20480; echo 90010001 >"$FAKE/cfg/$D/0x100"
	conf "CARDS=\"$D\""; boot
	check "unchained VSEC: S1" has "$CDIR/out" "$D 10de:2206/10de:146d: S1 no VSEC"
	untouched_610 $D
}
run_case 10-s5-forced "S1 on a plain layout; S5 when ReBAR sits elsewhere; route=0x610! waives S5 only" c10

c11() {
	card $A rbbc=000ffc00; card $B rbbc=001ffc00; vram $A 20480; vram $B 20480
	boot; check "rc 0" eq "$RC" 0
	check "$A: natively listed -> resize-only" has "$CDIR/out" "$A resized to 32768 MiB \(resize only, 0x610 untouched\)$"
	check "$B: smallest listed >= target" eq "$(bar_mib $B)" 32768
	untouched_610 $A $B
}
run_case 11-auto-resize-only "capability already lists the target: resize-only, 0x610 never written" c11

c12() {
	card $A bar1=32768 rbbc=000ffc00 r610=00001001; card $B bar1=65536 rbbc=001ffc00; vram $A 20480; vram $B 20480
	boot; check "$A already big" has "$CDIR/out" "$A BAR1 already 32768 MiB, skip$"
	check "$B never shrunk" has "$CDIR/out" "$B BAR1 already 65536 MiB, skip$"
	untouched_610 $A $B
	check "no resize" eq "$(count $A resizes)/$(count $B resizes)" 0/0
}
run_case 12-already-big "BAR1 >= target: nothing written; a larger BAR1 is never shrunk" c12

c13() {
	card $A; card $B; card $C; vram $A 20480; vram $B 20480; vram $C 20480
	touch "$FAKE/cfg/$A/no-widen" "$FAKE/cfg/$B/narrow"; echo 0 >"$FAKE/cfg/$C/latch-0x610"
	boot; check "rc 0" eq "$RC" 0
	check "nowiden" has "$CDIR/out" "$A capability did not widen to 32768 MiB \(before 00001c00, after 00001c00\); disarmed, skip resize$"
	check "narrow: superset" has "$CDIR/out" "$B capability lost sizes it listed before arming \(before 00001c00, after 000ff800\); disarmed, skip resize$"
	check "nolatch" has "$CDIR/out" "$C 0x610 did not latch \(reads 00001001\); disarmed, skip resize$"
	back_stock $A $B $C
	check "no resize" eq "$(count $A resizes)/$(count $B resizes)/$(count $C resizes)" 0/0/0
}
run_case 13-verify-fail "nowiden, narrow (superset check), nolatch: each backed off to stock" c13

c14() {
	card $A; vram $A 20480; touch "$FAKE/cfg/$A/kill-read-after-arm"
	card $B; vram $B 20480
	boot; check "$A killed read-back: did not latch" has "$CDIR/out" "$A 0x610 did not latch \(reads 00001c81\); disarmed, skip resize$"
	back_stock $A; large $B
}
run_case 14-readback-killed "the 0x610 read-back killed: backed off, never left armed" c14

c15() {
	card $A r610=00001c81 rbbc=000ffc00; vram $A 20480
	boot; check "armed at stock BAR1 (warm boot): resized" has "$CDIR/out" "$A armed and resized to 32768 MiB$"
	check "no new 0x610 write" eq "$(count $A writes)" 0
	card $B r610=00001c81 rbbc=000ffc00 fail=resize; vram $B 20480
	conf "CARDS=\"$B\""; boot
	check "failed: restored to stock 0" eq "$(reg $B 0x610)" 00001001
}
run_case 15-armed-earlier "0x610 armed by an earlier boot: resize; on failure restored to stock" c15

c16() {
	card $A fail=610; card $B fail=resize; card $C; vram $A 20480; vram $B 20480; vram $C 20480
	boot; check "rc 0" eq "$RC" 0
	check "write failed" has "$CDIR/out" "$A 0x610 write failed$"
	check "resize failed, disarmed" has "$CDIR/out" "$B resize failed \(Permission denied, see dmesg\); disarmed, left at stock 256 MiB$"
	stock $A; back_stock $B; large $C
	card $D fail=resize latch=1; vram $D 20480
	conf "CARDS=\"$D\""; boot
	check "disarm failed logged" has "$CDIR/out" "$D resize failed \(Permission denied\) and disarm failed \(0x610=00001c81, 0xbbc=000ffc00\)$"
}
run_case 16-failures "0x610 write fails; resize fails (disarmed); disarm fails (logged)" c16

c17() {
	card $A fail=noresize; card $B layout=plain rbbc=000ffc00 fail=noresize; vram $A 20480; vram $B 20480
	boot
	check "no success claim" hasnt "$CDIR/out" "$A armed and resized|$B resized to"
	check "0x610 route failure" has "$CDIR/out" "$A resize failed \(resize reported success but BAR1 is 256 MiB, see dmesg\); disarmed, left at stock 256 MiB$"
	check "resize-only failure" has "$CDIR/out" "$B resize failed \(resize reported success but BAR1 is 256 MiB\); left at its current 256 MiB$"
	back_stock $A
}
run_case 17-length-decides "resize reports success, BAR1 keeps its length: failure on both routes" c17

c18() {
	card $S1 under="$U1" fail=nospc start=0x1080000000 bar1reg=0x1000000000; vram $S1 20480
	boot; check "rewritten" has "$CDIR/out" "$S1 BAR1 register was left at 0x1000000000 by the failed resize; rewritten to the kernel's 0x0000001080000000$"
	check "registers = resource" eq "$(reg $S1 0x14) $(reg $S1 0x18)" "8000000c 00000010"
	card $S2 under="$U2" fail=nospc start=0x1060000000 bar3reg=0x1000000000; vram $S2 20480
	conf "CARDS=\"$S2\""; boot
	check "BAR3 mismatch: held" eq "$(ovr $S2)" geforce-bar1-hold
	check "log: held" has "$CDIR/out" "$S2 BAR registers disagree with the kernel: driver_override geforce-bar1-hold set, reboot required$"
}
run_case 18-bar-registers "failed resize: BAR1 register rewritten; other mismatch held (geforce-bar1-hold)" c18

c19() {
	card $A; card $B; vram $A 20480; vram $B 20480
	touch "$FAKE/cfg/$A/sigterm-on-arm"
	conf "CARDS=\"$A $B\""
	boot; check "exit 1" eq "$RC" 1
	large $A
	check "log: stop" has "$CDIR/out" "signal received; no further card is armed$"
	stock $B
}
run_case 19-sigterm-arming "SIGTERM while arming card 1: resolved, card 2 never armed, exit 1" c19

c20() {
	card $A; vram $A 20480; card $B layout=plain rbbc=000ffc00; vram $B 20480
	boot --dry-run; check "rc 0" eq "$RC" 0
	check "would arm" has "$CDIR/out" "$A would arm 0x610 VAL=9 and resize BAR1 to 32768 MiB$"
	check "would resize" has "$CDIR/out" "$B would resize BAR1 to 32768 MiB \(resize only\)$"
	check "last line" has "$CDIR/out" "dry run: nothing was written$"
	stock $A; untouched_610 $B
	check "no resize" eq "$(count $B resizes)" 0
	check "no state, no log file" eq "$(find "$CDIR/run" -mindepth 1 | wc -l)/$([ -e "$CDIR/gbr.log" ] && echo log || echo nolog)" "0/nolog"
	GBR_CONF=$CDIR/run.conf gbr plan; check "plan = dry run" has "$CDIR/out" "$A would arm 0x610"
	GBR_CONF=$CDIR/run.conf gbr boot --dry-run --card 10de:2684 --card $A
	check "--card filter" hasnt "$CDIR/out" "$B would"
}
run_case 20-dry-run "boot --dry-run / plan: would lines, nothing written; --card filters" c20

c21() {
	card $A; vram $A 20480
	oldconf "REBAR_BDFS=\"$A\"" "REBAR_IDS=\"10de:2206\"" "REBAR_N=9" "REBAR_LAYOUT=off" "REBAR_ARM=0x610"
	boot; check "rc 0" eq "$RC" 0; large $A
	check "deprecated BDFS" has "$CDIR/out" "deprecated key REBAR_BDFS=\"$A\"; use CARDS=\"$A\"$"
	check "deprecated N" has "$CDIR/out" "deprecated key REBAR_N=9; use SIZE=9$"
	check "deprecated ARM" has "$CDIR/out" "deprecated key REBAR_ARM=0x610; use ROUTE=auto$"
	check "old files warning" has "$CDIR/out" "old 3080-20gb-rebar files still present: .*rebar-arm.conf"
	card $B id=10de:2204; card $C layout=plain id=$T rbbc=000ffc00
	rm "$ROOT/etc/rebar-arm.conf"
	conf "REBAR_BDFS=\"$B\""; boot
	check "REBAR_IDS default absent: only CARDS" has "$CDIR/out" "$B 10de:2204/10de:146d \(untested\) size from config, target 32768 MiB"
	conf "REBAR_BDFS=\"$C\"" "REBAR_IDS=\"10de:2206\"" REBAR_ARM=none; boot
	check "REBAR_IDS filter" has "$CDIR/out" "$C is $T, not in REBAR_IDS \(10de:2206\), skip$"
	conf "REBAR_BDFS=\"$C\"" REBAR_ARM=none; boot
	check "REBAR_ARM=none -> resize" has "$CDIR/out" "deprecated key REBAR_ARM=none; use ROUTE=resize$"
	check "resize-only" has "$CDIR/out" "$C resized to 32768 MiB \(resize only, 0x610 untouched\)$"
	untouched_610 $C
}
run_case 21-legacy-config "old /etc/rebar-arm.conf read and mapped; REBAR_N default 9; REBAR_IDS filter" c21

c22() {
	card $A; vram $A 20480
	conf "SIZE=14" "ROUTE=sideways" "LAYOUT=bogus"
	boot; check "SIZE invalid" has "$CDIR/out" "SIZE=14 invalid \(auto, 0..13 or 64M..512G\); using auto$"
	check "ROUTE invalid" has "$CDIR/out" "ROUTE=sideways invalid"
	check "LAYOUT invalid" has "$CDIR/out" "LAYOUT=bogus invalid \(off, auto, dryrun, force\); using off$"
	large $A
	card $B; vram $B 1048576
	conf "CARDS=\"$B\""; boot
	check "n > 13 skipped" has "$CDIR/out" "$B route skip: VRAM 1048576 MiB needs n = 14, above the ReBAR maximum 512 GiB \(n = 13\)$"
	stock $B
	conf "CARDS=\"\""; boot; check "empty CARDS" has "$CDIR/out" "CARDS is empty, nothing to do$"
}
run_case 22-bad-values "invalid config values logged and defaulted; n > 13 skipped; empty CARDS" c22

# --- console ---------------------------------------------------------------------------------------------------------
c23() {
	card $A console=1 fb=BOOTFB; vram $A 20480
	card $B class=0x030200 fb=efifb; vram $B 20480
	boot; check "rc 0" eq "$RC" 0; large $A
	check "handover logged" has "$CDIR/out" "$A console card: the kernel removes the firmware framebuffer \(BOOTFB@BAR1\) before the resize$"
	check "handover: console returns" has "$CDIR/out" "$A the console returns when nvidia-drm \(fbdev=1\) or a display server takes over$"
	check "0302 with fb: skipped" has "$CDIR/out" "$B route skip: firmware framebuffer \(efifb@BAR1\) inside BAR1 of a non-VGA function; the kernel would not remove it$"
	stock $B
	conf 'declare -A CARD=(' "  [$B]=\"route=0x610\"" ')'; boot
	check "0302 rule has no override" has "$CDIR/out" "$B route skip: firmware framebuffer"
	card $C console=1; vram $C 20480
	conf "CONSOLE=skip"; boot
	check "CONSOLE=skip" has "$CDIR/out" "$C route skip: console card \(console=skip\)$"
	stock $C
}
run_case 23-console "console VGA: handover logged and resized; 0302 with fb skipped; CONSOLE=skip" c23

c24() {
	card $S1 under="$U1" console=1 fb=BOOTFB fail=nospc audio=1; vram $S1 20480
	conf LAYOUT=auto; boot
	check "console behind a switch: hint" has "$CDIR/out" "$S1 is the console card: the layout module refuses its root port$"
	check "console behind a switch: advice" has "$CDIR/out" "$S1 put it on a CPU root port, or set console=skip"
	card $A id=10de:1e07 console=1; vram $A 8192
	conf "CARDS=\"$A\""; boot
	check "Turing console: int10h note" has "$CDIR/out" "$A note: on this family"
	echo "options nvidia-drm modeset=1 fbdev=1" >"$FAKE/modprobe-c"; boot
	check "nvidia-drm fbdev configured: no note" hasnt "$CDIR/out" "$A note: on this family"
}
run_case 24-console-hints "console card behind a switch: module hint; non-Ampere/Ada console: int10h note" c24

# --- layout module ---------------------------------------------------------------------------------------------------
c30() {
	card $A; card $S1 under="$U1" fail=nospc audio=1; card $S2 under="$U2" fail=nospc audio=1
	vram $A 20480; vram $S1 20480; vram $S2 20480
	conf LAYOUT=auto; boot; check "rc 0" eq "$RC" 0
	large $A
	check "kept armed for the module" has "$CDIR/out" "$S1 resize failed \(No space left on device\); left armed for the layout module \(a PCIe switch above it\?\)$"
	check "one modprobe, both, size 15" eq "$(cat "$FAKE/modprobe.calls")" "targets=$S1,$S2 bar=1 size=15 dry_run=0"
	for f in $S1 0000:0c:00.1 $S2 0000:0d:00.1; do check "$f held during modprobe" eq "$(ovr_at "$f")" geforce-bar1-hold; done
	for f in $S1 0000:0c:00.1 $S2 0000:0d:00.1; do check "$f released" eq "$(ovr "$f")" ""; done
	check "log: module lines" has "$CDIR/out" "gbr_layout: root 0000:00:03.0 result ok$"
	check "log: modprobe line" has "$CDIR/out" "modprobe gbr_layout targets=$S1,$S2 size=15 dry_run=0: exit 0$"
	check "log: via the module" has "$CDIR/out" "$S2 armed and resized to 32768 MiB via the layout module$"
	armed_large $S1 $S2
	check "state: enlarged" has "$CDIR/run/cards" "^$S2 0x610 enlarged$"
	boot; check "rerun: no second module run" eq "$(lines modprobe.calls)" 1
}
run_case 30-layout-auto "auto: ENOSPC cards in one module run, hold and release; direct card plain" c30

c31() {
	card $S1 under="$U1" fail=nospc audio=1; card $S2 under="$U2" fail=nospc audio=1
	card 0000:0e:00.0 under="0000:00:04.0 0000:10:00.0 0000:11:08.0" fail=nospc
	vram $S1 20480; vram $S2 49140; vram 0000:0e:00.0 20480
	conf LAYOUT=auto; boot
	check "two batches (size 16, size 15)" eq "$(cat "$FAKE/modprobe.calls")" "targets=$S2 bar=1 size=16 dry_run=0
targets=$S1,0000:0e:00.0 bar=1 size=15 dry_run=0"
	check "batch line" has "$CDIR/out" "layout batch 2/2: root ports"
	check "$S2 64 GiB" eq "$(bar_mib $S2)" 65536
	check "$S1 32 GiB" eq "$(bar_mib $S1)" 32768
	check "hold released once, after both" eq "$(grep -c 'driver hold released' "$CDIR/out")" 1
}
run_case 31-layout-batches "mixed sizes: one module run per size index; one hold over all batches" c31

c32() {
	local i bdfs="" b
	for i in 1 2 3 4 5; do
		b=$(printf '0000:%02x:00.0' $((0x20 + i)))
		card "$b" under="$(printf '0000:00:%02x.0 0000:%02x:00.0 0000:%02x:08.0' $((0x10 + i)) $((0x30 + i)) $((0x40 + i)))" fail=nospc
		vram "$b" 20480; bdfs+=" $b"
	done
	conf LAYOUT=force; boot
	check "5 roots: 2 batches" eq "$(lines modprobe.calls)" 2
	check "first batch has 4 targets" eq "$(head -n 1 "$FAKE/modprobe.calls" | tr , '\n' | grep -c 0000:)" 4
	check "force: no resize write" eq "$(for b in $bdfs; do count "$b" resizes; done | sort -u)" 0
}
run_case 32-layout-5-roots "LAYOUT=force with 5 root ports: batches of at most 4 roots" c32

c33() {
	card $S1 under="$U1" fail=nospc audio=1; vram $S1 20480
	conf LAYOUT=auto; echo rollback-failed >"$FAKE/layout-mode"; boot
	check "hold kept" eq "$(ovr $S1)/$(ovr 0000:0c:00.1)" "geforce-bar1-hold/geforce-bar1-hold"
	check "no drivers_probe" eq "$(lines sys/bus/pci/drivers_probe)" 0
	check "log: rollback failed" has "$CDIR/out" "gbr_layout rollback failed: driver hold kept on .*; reboot required$"
	check "log: card left" has "$CDIR/out" "$S1 state unknown after the failed rollback, 0x610 left as is; reboot required$"
	check "0x610 still armed" eq "$(reg $S1 0x610)" 00001c81
}
run_case 33-layout-rollback-failed "rollback-failed: hold kept, 0x610 left, reboot required" c33

c34() {
	card $S1 under="$U1" fail=nospc audio=1; card $S2 under="$U2" fail=nospc audio=1; vram $S1 20480; vram $S2 20480
	conf LAYOUT=auto; echo nospace >"$FAKE/layout-mode"; touch "$FAKE/sigterm-in-modprobe"; boot
	check "exit 1" eq "$RC" 1
	check "log: signal resolved" has "$CDIR/out" "signal received; resolved the cards and the hold, exiting 1$"
	back_stock $S1 $S2
	check "disarmed before the release" before "$CDIR/out" "$S2 layout did not resize BAR1; disarmed" "driver hold released on"
}
run_case 34-sigterm-in-module "SIGTERM in the module: cards disarmed before the release, exit 1" c34

c35() {
	card $S1 under="$U1" fail=nospc audio=1; vram $S1 20480
	conf LAYOUT=auto; echo nolog-killed >"$FAKE/layout-mode"; boot
	check "unknown outcome" has "$CDIR/out" "gbr_layout outcome unknown \(modprobe exit 137, no result in the kernel log\)$"
	check "unknown outcome: hold kept" has "$CDIR/out" "[0-9]   driver hold kept on .*; reboot required$"
	check "hold kept" eq "$(ovr $S1)" geforce-bar1-hold
	echo nolog-reject >"$FAKE/layout-mode"; card $S2 under="$U2" fail=nospc audio=1; vram $S2 20480
	conf "CARDS=\"$S2\"" LAYOUT=auto; boot
	check "rejected module: refusal" has "$CDIR/out" "gbr_layout did not run or changed nothing \(modprobe exit 1, see its error above\)$"
	check "rejected module: cards stock, hold released" has "$CDIR/out" "[0-9]   the cards go back to stock and the hold is released$"
	back_stock $S2
	echo nolog-notrecoverable >"$FAKE/layout-mode"; card 0000:0e:00.0 under="0000:00:04.0 0000:10:00.0 0000:11:08.0" fail=nospc; vram 0000:0e:00.0 20480
	conf "CARDS=\"0000:0e:00.0\"" LAYOUT=auto; boot
	check "not recoverable without log: rollback-failed" has "$CDIR/out" "gbr_layout rollback failed"
}
run_case 35-module-outcomes "unknown module outcome keeps the hold; a rejected module is a refusal; not-recoverable" c35

c36() {
	card $S1 under="$U1" fail=nospc audio=1; vram $S1 20480
	conf LAYOUT=dryrun; boot
	check "dry_run=1" eq "$(cat "$FAKE/modprobe.calls")" "targets=$S1 bar=1 size=15 dry_run=1"
	check "dry run disarmed" has "$CDIR/out" "$S1 layout dry run only; disarmed, left at stock 256 MiB$"
	touch "$FAKE/no-module"; conf LAYOUT=auto; boot
	check "module missing" has "$CDIR/out" "gbr_layout module not found for kernel .* \(install.sh --layout-module builds it\)$"
	back_stock $S1
	card $S2 under="$U2" layout=plain rbbc=000ffc00 fail=noent; vram $S2 20480
	rm "$FAKE/no-module"; conf "CARDS=\"$S2\"" LAYOUT=auto; boot
	check "resize-only ENOENT to the module" has "$CDIR/out" "$S2 resize failed \(No such file or directory\); left to the layout module"
	check "resize-only via module" has "$CDIR/out" "$S2 resized to 32768 MiB via the layout module \(resize only, 0x610 untouched\)$"
	untouched_610 $S2
}
run_case 36-layout-dryrun-missing-enoent "dryrun; module missing; resize-only ENOENT handed to the module" c36

c37() {
	card $S1 under="$U1" fail=nospc audio=vfio-pci; card $S2 under="$U2" fail=nospc audio=bound; vram $S1 20480; vram $S2 20480
	conf LAYOUT=auto; boot
	check "vfio-pci kept" eq "$(ovr_at 0000:0c:00.1)/$(ovr 0000:0c:00.1)" "vfio-pci/vfio-pci"
	check "bound audio logged" has "$CDIR/out" "0000:0d:00.1 is bound to snd_hda_intel; the layout refuses its root port$"
}
run_case 37-layout-overrides "hold keeps vfio-pci and skips a bound function" c37

# --- repair, check --------------------------------------------------------------------------------------------------
c40() {
	card $A bound=1 bar1=32768; card $B bound=1 bar1=32768 r610=00001c81 rbbc=000ffc00; card $C; card $D bound=1
	for b in $A $B $C $D; do vram $b 20480; done
	conf "CARDS=\"$A $B $C $D\""; GBR_CONF=$ROOT/etc/geforce-bar1-resize.conf gbr repair
	check "re-armed" has "$CDIR/out" "$A bound; re-armed after reset, 0xbbc now 000ffc00$"
	check "$A armed, 32 GiB, no resize" eq "$(reg $A 0x610) $(cap $A) $(bar_mib $A) $(count $A resizes)" "00001c81 000ffc00 32768 0"
	check "$B wide: no write" eq "$(count $B writes)" 0
	check "$C unbound skipped" has "$CDIR/out" "$C not bound; repair only touches bound cards, skip$"
	check "$D small BAR: skipped" has "$CDIR/out" "$D bound with BAR1 256 MiB, not the target; repair skips"
	stock $C $D
}
run_case 40-repair "repair: re-arms a bound enlarged card after a reset; skips others" c40

c41() {
	card $A bound=1 r610=00001c81 rbbc=000ffc00; card $B layout=gb rbbc=000ffc00; card $C
	vram $A 20480; vram $B 20480
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09  Release Build" >"$FAKE/nv/version"
	GBR_CONF=/nonexistent gbr check; check "rc 1 ($C has no VRAM)" eq "$RC" 1
	check "$A plan none? no: BAR1 256 with 0x610 armed -> 0x610 route" has "$CDIR/out" "PLAN    arm 0x610 VAL=9, resize to 32768 MiB"
	check "$B resize-only" has "$CDIR/out" "PLAN    resize-only to 32768 MiB"
	check "$B S1 FAIL line" has "$CDIR/out" "FAIL S1 no VSEC"
	check "$C skip" has "$CDIR/out" "PLAN    skip: VRAM unknown"
	check "read-only" eq "$(count $A writes)/$(count $B writes)/$(count $C writes)/$(count $A resizes)" 0/0/0/0
	GBR_CONF=/nonexistent gbr check --vram 20G $C; check "--vram: rc 0" eq "$RC" 0
	check "--vram plan" has "$CDIR/out" "size    VRAM 20480 MiB \(--vram\), target 32768 MiB"
	check "label verified" has "$CDIR/out" "label   verified$"
	GBR_CONF=/nonexistent gbr check --report --vram 20G $C
	check "report row" has "$CDIR/out" "^\| .* \| 10de:2206/10de:146d \| .* \| 20480 MiB \| 0x610 \| 9 \| 256 MiB \| 615.71.09 \| .* \| direct \| no \| <outcome> \| <issue> \| "
}
run_case 41-check "check: per-card plan, S lines, label, --vram, --report; read-only" c41

c42() {
	card $S1 under="$U1" audio=1; vram $S1 20480
	GBR_CONF=/nonexistent gbr check --layout-plan $S1
	check "module dry run" eq "$(cat "$FAKE/modprobe.calls")" "targets=$S1 bar=1 size=15 dry_run=1"
	check "plan printed" has "$CDIR/out" "gbr_layout: root 0000:00:03.0 result dry-run$"
	check "switch line" has "$CDIR/out" "switch  behind a PCIe switch: yes$"
	check "no write, no hold" eq "$(count $S1 writes)/$(ovr $S1)" "0/(null)"
}
run_case 42-check-layout-plan "check --layout-plan: module dry run, no write" c42

# --- record ----------------------------------------------------------------------------------------------------------
c50() {
	card $A bound=1; card $B bound=1 id=10de:2684 sub=1458:4105
	gbr record; check "no driver: nothing" has "$CDIR/out" "record: the nvidia driver is not loaded"
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	printf '00000000:05:00.0, 20480, 615.71.09\n00000000:06:00.0, 49140, 615.71.09\n' >"$FAKE/smi"
	gbr record; check "rc 0" eq "$RC" 0
	check "record A" has "$ROOT/etc/geforce-bar1-resize/vram" "^$A 10de:2206/10de:146d 20480 615.71.09 [0-9-]+$"
	check "record B" has "$ROOT/etc/geforce-bar1-resize/vram" "^$B 10de:2684/1458:4105 49140 615.71.09 [0-9-]+$"
	check "driver option written" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
	cp "$ROOT/etc/geforce-bar1-resize/vram" "$CDIR/vram.1"
	rm -f "$FAKE/smi.calls"
	gbr record $A; check "unchanged: same file" eq "$(cmp -s "$CDIR/vram.1" "$ROOT/etc/geforce-bar1-resize/vram" && echo same)" same
	check "known card: nvidia-smi not run" absent "$FAKE/smi.calls"
	printf '00000000:05:00.0, 20480, 620.10\n' >"$FAKE/smi"
	gbr record; check "driver change re-recorded" has "$ROOT/etc/geforce-bar1-resize/vram" "^$A .* 20480 620.10 "
	check "unverified driver noted" has "$CDIR/out" "record: $A driver 620.10; RMForceStaticBar1=0 verified on 615.71.09 only$"
	check "B kept" has "$ROOT/etc/geforce-bar1-resize/vram" "^$B "
}
run_case 50-record "record: nvidia-smi per card into the record; unchanged no-op; driver option follows" c50

c51() {
	# an SR-IOV virtual function bound to nvidia (vGPU hosts): the udev rule leaves it out, and record skips it silently
	local vf=0000:05:00.4
	card $A bound=1; card $vf bound=1
	ln -s "$FAKE/sys/bus/pci/devices/$A" "$FAKE/sys/bus/pci/devices/$vf/physfn"
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	printf '00000000:05:00.0, 20480, 615.71.09\n' >"$FAKE/smi"
	check "udev rule: not for a VF" has "$PUB/udev/90-geforce-bar1-resize.rules" '^ACTION=="bind", .*TEST!="physfn", RUN\+='
	conf RECORD_DELAY=600
	gbr record --delay $vf; check "rc 0" eq "$RC" 0
	check "VF: no line" eq "$(wc -l <"$CDIR/out")" 0
	check "VF: nvidia-smi not run" absent "$FAKE/smi.calls"
	check "VF: nothing recorded" absent "$ROOT/etc/geforce-bar1-resize/vram"
}
run_case 51-record-vf "record: an SR-IOV virtual function gets no record run (udev rule, record itself)" c51

c52() {
	# record BDF (the record unit): a card the record holds with the same ids gets no nvidia-smi run and no wait; other
	# ids are queried
	card $A bound=1; card $B bound=1; vram $A 20480; vram $B 20480 10de:2206/10de:9999
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	printf '00000000:05:00.0, 20480, 615.71.09\n00000000:06:00.0, 20480, 615.71.09\n' >"$FAKE/smi"
	cp "$ROOT/etc/geforce-bar1-resize/vram" "$CDIR/vram.0"
	conf RECORD_DELAY=600
	local t0=$SECONDS
	gbr record --delay $A; check "rc 0" eq "$RC" 0
	check "known: no wait" eq "$([ $((SECONDS - t0)) -lt 60 ] && echo yes)" yes
	check "known: one line" eq "$(wc -l <"$CDIR/out")" 1
	check "known: the line" has "$CDIR/out" "record: $A 10de:2206/10de:146d VRAM 20480 MiB already recorded; nvidia-smi not run$"
	check "known: nvidia-smi not run" absent "$FAKE/smi.calls"
	check "known: record untouched" eq "$(cmp -s "$CDIR/vram.0" "$ROOT/etc/geforce-bar1-resize/vram" && echo same)" same
	gbr record $B; check "other ids: queried" present "$FAKE/smi.calls"
	check "other ids: re-recorded" has "$ROOT/etc/geforce-bar1-resize/vram" "^$B 10de:2206/10de:146d 20480 615.71.09 "
}
run_case 52-record-known "record BDF: a card already recorded with its ids gets no nvidia-smi run" c52

c53() {
	# record --delay BDF (the record unit) for a card without a record: RECORD_DELAY first, then nvidia-smi for a card
	# still bound to nvidia; a card unbound during the wait is skipped
	card $A bound=1; card $B bound=1
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	printf '00000000:05:00.0, 20480, 615.71.09\n00000000:06:00.0, 20480, 615.71.09\n' >"$FAKE/smi"
	conf RECORD_DELAY=1
	local t0 ms un
	t0=$(date +%s%N)
	gbr record --delay $A; ms=$((($(date +%s%N) - t0) / 1000000))
	check "rc 0" eq "$RC" 0
	check "unknown: waited RECORD_DELAY first" eq "$([ "$ms" -ge 1000 ] && echo yes || echo "no, $ms ms")" yes
	check "unknown: then nvidia-smi" present "$FAKE/smi.calls"
	check "unknown: recorded" has "$ROOT/etc/geforce-bar1-resize/vram" "^$A 10de:2206/10de:146d 20480 615.71.09 "
	rm -f "$FAKE/smi.calls"
	conf RECORD_DELAY=2
	(sleep 0.5; rm "$FAKE/sys/bus/pci/devices/$B/driver") &
	un=$!
	gbr record --delay $B; wait "$un"
	check "unbound during the wait: rc 0" eq "$RC" 0
	check "unbound during the wait: skipped" has "$CDIR/out" "record: $B no longer bound to nvidia after 2 s; nothing recorded$"
	check "unbound: nvidia-smi not run" absent "$FAKE/smi.calls"
	check "unbound: not recorded" hasnt "$ROOT/etc/geforce-bar1-resize/vram" "^$B "
	conf RECORD_DELAY=soon; boot --dry-run
	check "invalid RECORD_DELAY logged" has "$CDIR/out" "RECORD_DELAY=soon invalid \(0\.\.3600 seconds\); using 60$"
}
run_case 53-record-delay "record --delay: waits RECORD_DELAY, then only a card still bound to nvidia is queried" c53

c54() {
	# the VRAM of a card changes but its ids stay (memory mod, a card swapped for one with the same ids): the record
	# unit (record --delay BDF) keeps the old size, and the next boot plans from it; record without an address
	# re-queries every card and the boot after it plans from the new size
	card $A bound=1; card $B bound=1; vram $A 10240; vram $B 20480
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	printf '00000000:05:00.0, 20480, 615.71.09\n00000000:06:00.0, 20480, 615.71.09\n' >"$FAKE/smi"
	conf RECORD_DELAY=600
	boot --dry-run; check "stale record: planned from it" has "$CDIR/out" "$A 10de:2206/10de:146d \(untested\) VRAM 10240 MiB \(record\), target 16384 MiB"
	check "stale record: BAR1 below the 20 GB" has "$CDIR/out" "$A would arm 0x610 VAL=8 and resize BAR1 to 16384 MiB$"
	gbr record --delay $A; check "record BDF: same ids, kept" has "$CDIR/out" "record: $A 10de:2206/10de:146d VRAM 10240 MiB already recorded; nvidia-smi not run$"
	check "record BDF: nvidia-smi not run" absent "$FAKE/smi.calls"
	gbr record; check "record: rc 0" eq "$RC" 0
	check "record: nvidia-smi run" present "$FAKE/smi.calls"
	check "record: new size logged" has "$CDIR/out" "record: $A 10de:2206/10de:146d VRAM 20480 MiB, driver 615.71.09$"
	check "record: new size stored" has "$ROOT/etc/geforce-bar1-resize/vram" "^$A 10de:2206/10de:146d 20480 615.71.09 "
	check "record: other card unchanged" has "$ROOT/etc/geforce-bar1-resize/vram" "^$B 10de:2206/10de:146d 20480 615.71.09 2026-11-01$"
	boot --dry-run; check "next boot planned from the new size" has "$CDIR/out" "$A 10de:2206/10de:146d \(verified\) VRAM 20480 MiB \(record\), target 32768 MiB"
}
run_case 54-record-vram-change "VRAM changed, same ids: record BDF keeps the old size; record without an address re-queries" c54

# --- driver option ----------------------------------------------------------------------------------------------------
c60() {
	card $A; card $B; card $C bar1=32768 rbbc=000ffc00; vram $A 20480; vram $B 20480; vram $C 20480
	conf "EXCLUDE=\"$B\""
	gbr driver-option --print; check "print: only enlarged" has "$CDIR/out" "^options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;\"$"
	check "nothing written by print" absent "$ROOT/$OPTF"
	gbr driver-option --write; check "write rc 0" eq "$RC" 0
	check "file" opt_is "pci=$A;RMForceStaticBar1=0;"
	echo "$C 0x610 enlarged" >"$CDIR/run/cards"
	gbr driver-option --write; check "enlarged this boot: listed" opt_is "pci=$A;RMForceStaticBar1=0;pci=$C;RMForceStaticBar1=0;"
	sed -i "s|pci=$A;RMForceStaticBar1=0;|pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;|" "$ROOT/$OPTF"
	gbr driver-option --write; check "hand-added key kept" opt_is "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$C;RMForceStaticBar1=0;"
	gbr driver-option --write; check "second write: unchanged" has "$CDIR/out" "^unchanged "
	check "backup kept (one rewrite)" eq "$(find "$ROOT/var/backups/geforce-bar1-resize" -name zz-geforce-bar1-resize.conf | wc -l)" 1
	conf "EXCLUDE=\"$B\"" 'declare -A CARD=(' "  [$C]=\"driver_option=off keys=RMDynBar1P2PEnable=0;\"" "  [$B]=\"keys=RmFoo=0x1;\"" ')'
	gbr driver-option --write; check "driver_option=off keeps user keys only; excluded card ignored" opt_is "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$C;RMDynBar1P2PEnable=0;"
	conf 'declare -A CARD=(' "  [$A]=\"keys=RMForceStaticBar1=1;\"" ')'
	rm -f "$CDIR/run/cards"
	gbr driver-option --write; check "user RMForceStaticBar1=1 after ours (wins)" has "$ROOT/$OPTF" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;RMForceStaticBar1=1;"
}
run_case 60-driver-option "driver-option: enlarged cards only, user keys kept, keys= merged, off per card" c60

c61() {
	card $A; card $B; vram $A 20480; vram $B 20480
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$B;RMDynBar1P2PEnable=0;\"" >"$ROOT/etc/modprobe.d/p2p.conf"
	echo 'options nvidia NVreg_RegistryDwords="RMForceStaticBar1=1;"' >"$ROOT/etc/modprobe.d/global.conf"
	gbr driver-option --write; check "foreign line: rc 3" eq "$RC" 3
	check "foreign named" has "$CDIR/out" "foreign NVreg_RegistryDwordsPerDevice line in .*/p2p.conf"
	check "merged line shown" has "$CDIR/out" "^options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;\"$"
	check "global warning" has "$CDIR/out" "global.conf sets RMForceStaticBar1 in the global NVreg_RegistryDwords"
	check "nothing written" absent "$ROOT/$OPTF"
	gbr driver-option --write --adopt-driver-line; check "adopt: rc 0" eq "$RC" 0
	check "merged" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	check "foreign commented out" has "$ROOT/etc/modprobe.d/p2p.conf" "^# adopted by geforce-bar1-resize: options nvidia"
	check "foreign backed up" eq "$(find "$ROOT/var/backups/geforce-bar1-resize" -name p2p.conf | wc -l)" 1
	gbr driver-option --write; check "after adopt: no foreign" eq "$RC" 0
	# a second per-device line next to ours: the boot run warns and names the command that merges them
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$B;RmFoo=1;\"" >"$ROOT/etc/modprobe.d/extra.conf"
	boot; check "two per-device lines: warning" has "$CDIR/out" "warning: more than one NVreg_RegistryDwordsPerDevice line \(.*\); only the last counts$"
	check "two per-device lines: the merge command" has "$CDIR/out" "[0-9]   sudo geforce-bar1-resize driver-option --write --adopt-driver-line merges them$"
}
run_case 61-driver-option-foreign "foreign per-device line stops --write (rc 3); --adopt-driver-line merges it" c61

c63() {
	card $A; vram $A 20480
	conf DRIVER_OPTION=off
	gbr driver-option --write; check "DRIVER_OPTION=off: no file" absent "$ROOT/$OPTF"
	check "said so" has "$CDIR/out" "no card needs the driver option"
	conf ""; gbr driver-option --write; present "$ROOT/$OPTF"
	conf DRIVER_OPTION=off; gbr driver-option --write; check "removed again" absent "$ROOT/$OPTF"
}
run_case 63-driver-option-off "DRIVER_OPTION=off: no file; an existing one is removed (backup kept)" c63

c64() {
	# the label table in the script is a subset of docs/hardware.md's verified/reported rows
	local row id route n
	while read -r row; do
		read -r id route n _ <<<"$row"
		check "hardware.md has $id $route n=$n" has "$PUB/docs/hardware.md" "\| *\`?$id\`? *\|.*\| *\`?$route\`? *\| *$n *\|.*(verified|reported)"
	done < <(sed -n '/^LABELS=(/,/^)/{s/^[[:space:]]*"\(.*\)"$/\1/p}' "$PUB/scripts/geforce-bar1-resize")
}
[ ! -e "$PUB/docs/hardware.md" ] || run_case 64-labels-hardware-md "label table is a subset of docs/hardware.md" c64

c68() {
	# a card that is large already (route none) is listed with RMForceStaticBar1=0 when the file listed it before, but
	# only for the same card: one swapped in with other ids (a stock card whose firmware gives a large BAR1) does not
	# inherit the old card's key under DRIVER_OPTION=auto; the same card at the same address keeps it (migration)
	card $A bound=1 layout=plain bar1=32768 rbbc=000ffc00 id=10de:2b85 sub=10de:2000
	vram $A 20480 10de:2206/10de:146d
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	local old="options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;\""
	echo "$old" >"$ROOT/$OPTF"
	conf SIZE=9
	gbr driver-option --write; check "swap, record of the old card: rc 0" eq "$RC" 0
	check "swap, record of the old card: no RMForceStaticBar1=0" hasnt "$ROOT/$OPTF" "RMForceStaticBar1=0"
	echo "$old" >"$ROOT/$OPTF"; conf ""
	printf '00000000:05:00.0, 32607, 615.71.09\n' >"$FAKE/smi"
	gbr record $A; check "swap, record unit: new card recorded" has "$ROOT/etc/geforce-bar1-resize/vram" "^$A 10de:2b85/10de:2000 32607 615.71.09 "
	check "swap, record unit: no RMForceStaticBar1=0 in the file it writes" hasnt "$ROOT/$OPTF" "RMForceStaticBar1=0"
	gbr driver-option --write; check "swap, later write: still none" hasnt "$ROOT/$OPTF" "RMForceStaticBar1=0"
	# the same card stays: the old file's listing is kept (as at a migration from 3080-20gb-rebar)
	card $B bound=1 layout=plain bar1=32768 rbbc=000ffc00; vram $B 20480
	printf '%s\n' "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$B;RMForceStaticBar1=0;\"" >"$ROOT/$OPTF"
	gbr driver-option --write; check "same card: kept" opt_is "pci=$B;RMForceStaticBar1=0;"
	printf '00000000:05:00.0, 32607, 615.71.09\n00000000:06:00.0, 20480, 615.71.09\n' >"$FAKE/smi"
	gbr record; check "same card: record keeps it" opt_is "pci=$B;RMForceStaticBar1=0;"
	# no record at the address yet (a migration before the driver has seen the card), size from the config: kept
	sed -i "/^$B /d" "$ROOT/etc/geforce-bar1-resize/vram"; conf SIZE=9
	gbr driver-option --write; check "no record yet: kept" opt_is "pci=$B;RMForceStaticBar1=0;"
}
run_case 68-driver-option-swap "route none: a card swapped in with other ids does not inherit RMForceStaticBar1=0; the same card keeps it" c68
