# shellcheck shell=bash disable=SC2154,SC2034,SC2086 # run.sh sets the variables; card addresses never need quoting
# SPDX-License-Identifier: MIT
# geforce-dynbar1-p2p (formerly 3080-20g-p2p) contract cases for tests/run.sh (sourced): per_device_configured/card_ok
# (contrib/3080-20g/common.sh) read our option file through the `modprobe -c` stand-in, which lists every modprobe.d
# file of $ROOT in kmod's order (by file name); common.sh takes the last per-device line.
# The published repository is cloned into $WORK once, under its current name or its former one (P2P_TREE: use an
# existing checkout instead). Without git or network access these cases are skipped, with a note.

P2P_URLS="https://github.com/noon-at-cgn/geforce-dynbar1-p2p https://github.com/noon-at-cgn/3080-20g-p2p"
P2P_STATE="" # "", ok or the reason the cases are skipped
p2p_tree() { # sets P2P_TREE; returns 1 (and sets SKIP) when there is none
	local u
	if [ -z "$P2P_STATE" ]; then
		if [ -n "${P2P_TREE:-}" ]; then
			P2P_STATE=ok
		elif ! command -v git >/dev/null; then
			P2P_STATE="git not found"
		else
			P2P_TREE=$WORK/geforce-dynbar1-p2p P2P_STATE="cannot clone $P2P_URLS (offline?)"
			for u in $P2P_URLS; do
				rm -rf "$P2P_TREE"
				if GIT_TERMINAL_PROMPT=0 timeout 120 git clone -q --depth 1 "$u" "$P2P_TREE" >>"$WORK/p2p-clone.log" 2>&1; then
					P2P_STATE=ok
					echo "geforce-dynbar1-p2p: cloned $u at $(git -C "$P2P_TREE" rev-parse --short HEAD)"
					break
				fi
			done
		fi
		[ "$P2P_STATE" = ok ] && [ ! -r "$P2P_TREE/contrib/3080-20g/common.sh" ] && P2P_STATE="no contrib/3080-20g/common.sh in $P2P_TREE"
	fi
	[ "$P2P_STATE" = ok ] && return 0
	SKIP="geforce-dynbar1-p2p not available: $P2P_STATE"
	return 1
}
modprobe_c() { find "$ROOT/etc/modprobe.d" -maxdepth 1 -name '*.conf' | LC_ALL=C sort | xargs -r cat >"$FAKE/modprobe-c"; }
p2p_run() { # P2P_ENABLE [static] BDF...: per_device_configured's messages, then CONFIGURED-OK when it passes
	local e=$1 s=""
	shift
	[ "$1" != static ] || { s=static; shift; }
	printf 'GPUS="%s"\nP2P_ENABLE=%s\nKVER=stand-in\n' "$*" "$e" >"$CDIR/p2p-config.sh"
	# shellcheck disable=SC2016 # expanded by the inner bash
	bash -c 'P2P_CONFIG=$1; . "$2/contrib/3080-20g/common.sh"; per_device_configured $3 && echo CONFIGURED-OK' _ "$CDIR/p2p-config.sh" "$P2P_TREE" "$s" 2>&1
}
p2p_expect() { # description want P2P_ENABLE [static] BDF...: card_ok prints exactly want
	local what=$1 want=$2 out
	shift 2
	modprobe_c
	out=$(p2p_run "$@")
	# shellcheck disable=SC2001 # prefixes every line
	sed "s/^/  [P2P_ENABLE='$1'] /" <<<"$out" >>"$LOG"
	check "$what" eq "$out" "$want"
}
last_key() { # BDF key: the value the driver uses for the card (the last one in its group)
	sed -n 's/.*NVreg_RegistryDwordsPerDevice="\([^"]*\)".*/\1/p' "$ROOT/$OPTF" | tr ';' '\n' |
		awk -v b="pci=$1" -v k="$2" -F= '$0 == b { on = 1; next } /^pci=/ { on = 0 } on && $1 == k { v = $2 } END { print v }'
}

c62() {
	# the file our generator writes: P2P on (no opt-out), P2P off (RMDynBar1P2PEnable=0 per card via keys=), keys=
	# removed again (the key goes), and an opt-out added by hand (kept on rewrite)
	p2p_tree || return 0
	card $A; card $B; vram $A 20480; vram $B 20480
	gbr driver-option --write
	p2p_expect "P2P on: per_device_configured" CONFIGURED-OK "" $A $B
	p2p_expect "P2P on file, P2P_ENABLE=0: card_ok refuses" "P2P_ENABLE=0 but no RMDynBar1P2PEnable=0 for $A
P2P_ENABLE=0 but no RMDynBar1P2PEnable=0 for $B" 0 $A $B
	conf 'declare -A CARD=(' '  [10de:2206]="keys=RMDynBar1P2PEnable=0;"' ')'
	gbr driver-option --write
	p2p_expect "P2P off via keys=: per_device_configured" CONFIGURED-OK 0 $A $B
	p2p_expect "P2P off, static check (fallback/rollback)" CONFIGURED-OK "" static $A $B
	conf ""
	gbr driver-option --write
	check "keys= removed: the opt-out goes" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
	p2p_expect "keys= removed: P2P on again" CONFIGURED-OK "" $A $B
	sed -i "s|pci=$B;RMForceStaticBar1=0;|pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;|" "$ROOT/$OPTF"
	gbr driver-option --write
	check "opt-out added by hand: kept on rewrite" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	p2p_expect "hand opt-out on $B, P2P_ENABLE empty: $B refused" \
		"RMDynBar1P2PEnable=0 set for $B (P2P off) but P2P_ENABLE is not 0" "" $A $B
	p2p_expect "hand opt-out on $B, P2P_ENABLE=0 for $B" CONFIGURED-OK 0 $B
}
run_case 62-p2p-contract "geforce-dynbar1-p2p card_ok accepts every group our generator writes" c62

c65() {
	# a user's RMForceStaticBar1=1 comes after our =0, so the driver uses 1 (static BAR1) for that card; the other
	# card is unaffected, and removing the key from the config removes it from the file
	p2p_tree || return 0
	card $A; card $B; vram $A 20480; vram $B 20480
	conf 'declare -A CARD=(' "  [$A]=\"keys=RMForceStaticBar1=1;\"" ')'
	gbr driver-option --write; check "write rc 0" eq "$RC" 0
	check "file: ours first, the user's =1 last" opt_is "pci=$A;RMForceStaticBar1=0;RMForceStaticBar1=1;pci=$B;RMForceStaticBar1=0;"
	check "driver's value for $A is 1, for $B 0" eq "$(last_key $A RMForceStaticBar1)/$(last_key $B RMForceStaticBar1)" 1/0
	p2p_expect "card $B alone passes" CONFIGURED-OK "" $B
	gbr driver-option --write; check "rewrite unchanged" has "$CDIR/out" "^unchanged "
	conf ""
	gbr driver-option --write
	check "keys= removed from the config: the =1 goes" eq "$(last_key $A RMForceStaticBar1)" 0
	p2p_expect "keys= removed: both pass" CONFIGURED-OK "" $A $B
}
run_case 65-p2p-user-static "user RMForceStaticBar1=1 wins in the driver; removing it from keys= restores ours" c65

c66() {
	# ten cards, including domain 0001 and addresses with hex letters; one line of 370 (P2P on) / 590 (off) characters
	p2p_tree || return 0
	local b all="" want="" off=""
	for b in 0000:0a:00.0 0000:0b:00.0 0000:1a:00.0 0000:21:00.0 0000:41:00.0 0000:61:00.0 0000:81:00.0 0000:a1:00.0 \
		0000:c1:00.0 0001:01:00.0; do
		card $b; vram $b 20480; all+=" $b"
	done
	# shellcheck disable=SC2086 # card list
	for b in $(printf '%s\n' $all | LC_ALL=C sort); do
		want+="pci=$b;RMForceStaticBar1=0;" off+="pci=$b;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	done
	gbr driver-option --write; check "write rc 0" eq "$RC" 0
	check "ten groups, address order" opt_is "$want"
	check "no length warning (${#want} characters)" hasnt "$CDIR/out" "option line is"
	# shellcheck disable=SC2086
	p2p_expect "ten cards, P2P on" CONFIGURED-OK "" $all
	conf 'declare -A CARD=(' '  [10de:2206]="keys=RMDynBar1P2PEnable=0;"' ')'
	gbr driver-option --write
	check "ten groups with the opt-out" opt_is "$off"
	check "no length warning (${#off} characters)" hasnt "$CDIR/out" "option line is"
	# shellcheck disable=SC2086
	p2p_expect "ten cards, P2P off" CONFIGURED-OK 0 $all
	# shellcheck disable=SC2086
	p2p_expect "ten cards, P2P off file, P2P_ENABLE empty: every card refused" \
		"$(for b in $all; do echo "RMDynBar1P2PEnable=0 set for $b (P2P off) but P2P_ENABLE is not 0"; done)" "" $all
}
run_case 66-p2p-ten-cards "ten cards: one line, every group passes p2p card_ok (on, off, mismatch refused)" c66

c67() {
	# the old zz-nvidia-static-bar1.conf next to ours (driver-option without install.sh): its opt-out is carried over;
	# while both files exist modprobe -c lists the old line last (zz-n after zz-g), the one the driver and card_ok read
	p2p_tree || return 0
	card $A; card $B; vram $A 20480; vram $B 20480
	local old=$ROOT/etc/modprobe.d/zz-nvidia-static-bar1.conf
	printf '# Written by install.sh (3080-20gb-rebar).\noptions nvidia NVreg_RegistryDwordsPerDevice="%s"\n' \
		"pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;" >"$old"
	p2p_expect "old file only" CONFIGURED-OK 0 $A $B
	gbr driver-option --write; check "write rc 0, old file not foreign" eq "$RC" 0
	check "opt-out carried over from the old file" opt_is "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	check "old file left to install.sh" present "$old"
	p2p_expect "both files (old line last)" CONFIGURED-OK 0 $A $B
	check "modprobe -c: old line last" eq "$(grep '^options' "$FAKE/modprobe-c" | tail -n 1)" "$(grep '^options' "$old")"
	mkdir -p "$CDIR/moved" && mv "$old" "$CDIR/moved/"
	p2p_expect "new file only (old moved away, as install.sh does)" CONFIGURED-OK 0 $A $B
	gbr driver-option --write; check "rewrite without the old file: unchanged" has "$CDIR/out" "^unchanged "
}
run_case 67-p2p-old-file "old zz-nvidia-static-bar1.conf: opt-out kept; card_ok passes before, with both files, after" c67

# --- through install.sh ---------------------------------------------------------------------------------------------
c90() {
	p2p_tree || return 0
	card $A; card $B; smi_for $A:20480 $B:20480
	inst; check "rc 0" eq "$RC" 0
	check "option file" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
	p2p_expect "fresh install, P2P on" CONFIGURED-OK "" $A $B
	p2p_expect "fresh install, static check" CONFIGURED-OK "" static $A $B
}
run_case 90-p2p-install-fresh "fresh install.sh: p2p card_ok passes every card" c90

c91() {
	p2p_tree || return 0
	card $A; card $B; smi_for $A:20480 $B:20480
	old_install 1 "$A $B" "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	p2p_expect "old install, P2P off" CONFIGURED-OK 0 $A $B
	inst; check "rc 0" eq "$RC" 0
	check "old option file moved" absent "$ROOT/etc/modprobe.d/zz-nvidia-static-bar1.conf"
	check "option file with the opt-out" opt_is "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	p2p_expect "migrated, P2P off" CONFIGURED-OK 0 $A $B
	inst; check "second run rc 0" eq "$RC" 0
	p2p_expect "second install run, P2P off" CONFIGURED-OK 0 $A $B
}
run_case 91-p2p-install-migrate "install.sh migration with the P2P opt-out on both cards: card_ok passes before and after" c91
