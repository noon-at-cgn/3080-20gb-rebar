# shellcheck shell=bash disable=SC2154,SC2034,SC2086 # run.sh sets the variables; card addresses never need quoting
# SPDX-License-Identifier: MIT
# install.sh / uninstall.sh / migration cases for tests/run.sh (sourced).

tree_sum() { # ROOT: every file and link below it with its content hash or target
	(cd "$1" && find . \( -type f -o -type l \) -print | sort | while IFS= read -r f; do
		if [ -L "$f" ]; then echo "$f -> $(readlink "$f")"; else echo "$f $(sha256sum <"$f" | cut -c1-16)"; fi
	done)
}
smi_for() { # BDF:MIB...: the fake driver is loaded and reports these cards
	echo "NVRM version: NVIDIA UNIX x86_64 Kernel Module  615.71.09" >"$FAKE/nv/version"
	: >"$FAKE/smi"
	local a
	for a; do echo "0000${a%:*}, ${a##*:}, 615.71.09" >>"$FAKE/smi"; done
}
# an install of 3080-20gb-rebar (rebar-arm.sh), file for file as its install.sh left it, plus the keys and the layout
# module of unreleased development builds; the old script, unit and DKMS file are short stand-ins (only their
# presence and their moves are checked)
OLDKREL=6.8.0-1-generic
old_install() { # enabled(0|1) "BDFS" [option-line]
	mkdir -p "$ROOT/usr/local/sbin" "$ROOT/etc/systemd/system/rebar-arm.service.d" "$ROOT/etc/modprobe.d"
	printf '#!/bin/bash\n# rebar-arm.sh of 3080-20gb-rebar (test stand-in)\nexit 0\n' >"$ROOT/usr/local/sbin/rebar-arm.sh"
	chmod 755 "$ROOT/usr/local/sbin/rebar-arm.sh"
	printf '[Unit]\nDescription=Arm the BAR1 size override and resize BAR1 (3080-20gb-rebar, test stand-in)\nDefaultDependencies=no\n\n[Service]\nType=oneshot\nExecStart=/usr/local/sbin/rebar-arm.sh\n\n[Install]\nWantedBy=sysinit.target\n' \
		>"$ROOT/etc/systemd/system/rebar-arm.service"
	printf '[Service]\nEnvironment=REBAR_ARM_CONF=/etc/rebar-arm.conf\n' >"$ROOT/etc/systemd/system/rebar-arm.service.d/override.conf"
	printf '# /etc/rebar-arm.conf, written by install.sh.\nREBAR_BDFS="%s"\nREBAR_IDS="10de:2206"\nREBAR_N=9\nREBAR_LOG=/var/log/rebar-arm.log\nREBAR_LAYOUT=off\nREBAR_ARM=0x610\n' "$2" >"$ROOT/etc/rebar-arm.conf"
	[ -z "${3:-}" ] || printf '# Written by install.sh (3080-20gb-rebar).\noptions nvidia NVreg_RegistryDwordsPerDevice="%s"\n' "$3" >"$ROOT/etc/modprobe.d/zz-nvidia-static-bar1.conf"
	if [ "$1" = 1 ]; then
		mkdir -p "$ROOT/etc/systemd/system/sysinit.target.wants"
		ln -s /etc/systemd/system/rebar-arm.service "$ROOT/etc/systemd/system/sysinit.target.wants/rebar-arm.service"
	fi
	mkdir -p "$ROOT/usr/src/rebar-layout-0.1" "$ROOT/lib/modules/$OLDKREL/updates"
	printf 'PACKAGE_NAME="rebar-layout"\nPACKAGE_VERSION="0.1"\nBUILT_MODULE_NAME[0]="rebar_layout"\nDEST_MODULE_LOCATION[0]="/updates/dkms"\nAUTOINSTALL="yes"\n' \
		>"$ROOT/usr/src/rebar-layout-0.1/dkms.conf"
	echo stand-in >"$ROOT/lib/modules/$OLDKREL/updates/rebar_layout.ko"
}
OLDS="etc/rebar-arm.conf usr/local/sbin/rebar-arm.sh etc/systemd/system/rebar-arm.service etc/systemd/system/rebar-arm.service.d etc/systemd/system/sysinit.target.wants/rebar-arm.service etc/modprobe.d/zz-nvidia-static-bar1.conf usr/src/rebar-layout-0.1 lib/modules/$OLDKREL/updates/rebar_layout.ko"

c70() {
	card $A; card $B id=10de:2684 sub=1458:4105; smi_for $A:20480 $B:49140
	inst --enable; check "rc 0" eq "$RC" 0
	for f in usr/local/sbin/geforce-bar1-resize etc/systemd/system/geforce-bar1-resize.service etc/systemd/system/geforce-bar1-resize-record@.service etc/udev/rules.d/90-geforce-bar1-resize.rules etc/geforce-bar1-resize.conf etc/geforce-bar1-resize/vram; do
		check "installed /$f" present "$ROOT/$f"
	done
	check "default config" has "$ROOT/etc/geforce-bar1-resize.conf" "^CARDS=auto$"
	check "vram recorded" has "$ROOT/etc/geforce-bar1-resize/vram" "^$B 10de:2684/1458:4105 49140 "
	check "plan printed" has "$CDIR/install.out" "$A would arm 0x610 VAL=9 and resize BAR1 to 32768 MiB"
	check "plan: $B 64 GiB" has "$CDIR/install.out" "$B would arm 0x610 VAL=10 and resize BAR1 to 65536 MiB"
	check "driver option" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;"
	check "enabled (link)" eq "$(readlink "$ROOT/etc/systemd/system/sysinit.target.wants/geforce-bar1-resize.service")" /etc/systemd/system/geforce-bar1-resize.service
	check "unit runs boot" has "$ROOT/etc/systemd/system/geforce-bar1-resize.service" "^ExecStart=/usr/local/sbin/geforce-bar1-resize boot$"
	check "nothing written to the cards" eq "$(count $A writes)/$(count $B writes)" 0/0
	tree_sum "$ROOT" >"$CDIR/tree.1"
	inst --enable; check "second run rc 0" eq "$RC" 0
	tree_sum "$ROOT" >"$CDIR/tree.2"
	check "second run: tree byte-identical" same_tree "$CDIR/tree.1" "$CDIR/tree.2"
	inst --size 16G --exclude $B; check "flags change only their keys" has "$ROOT/etc/geforce-bar1-resize.conf" "^SIZE=16G$"
	check "EXCLUDE set" has "$ROOT/etc/geforce-bar1-resize.conf" "^EXCLUDE=$B$"
	check "config backed up" eq "$(find "$ROOT/var/backups/geforce-bar1-resize" -name geforce-bar1-resize.conf | wc -l)" 1
}
run_case 70-install-fresh "fresh install: files, record, plan, driver option, enable; rerun byte-identical" c70

c71() {
	card $A; card $B; card $C console=1
	smi_for $A:20480 $B:20480 $C:20480
	old_install 1 "$A $B" "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	inst; check "rc 0" eq "$RC" 0
	check "found the old install" has "$CDIR/install.out" "Found an install of 3080-20gb-rebar"
	check "CARDS = old REBAR_BDFS" has "$ROOT/etc/geforce-bar1-resize.conf" "^CARDS=\"$A $B\"$"
	check "SIZE = old REBAR_N" has "$ROOT/etc/geforce-bar1-resize.conf" "^SIZE=9$"
	check "P2P opt-out kept as keys= with ids" has "$ROOT/etc/geforce-bar1-resize.conf" "\[$B\]=\"ids=10de:2206/10de:146d keys=RMDynBar1P2PEnable=0;\""
	check "extra card CARDS=auto would add" has "$CDIR/install.out" "CARDS=auto would also enlarge: $C"
	check "option file merged" opt_is "pci=$A;RMForceStaticBar1=0;pci=$B;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	for f in $OLDS; do check "old /$f moved" absent "$ROOT/$f"; done
	local mig
	mig=$(find "$ROOT/var/backups/geforce-bar1-resize" -type d -name migrated-from-rebar-arm | head -n 1)
	check "old files in the backup" eq "$(cd "$mig" 2>/dev/null && find . \( -type f -o -type l \) | wc -l)" 9
	check "RESTORE.txt" has "$mig/RESTORE.txt" "rebar-arm.service was enabled"
	check "drop-in copied with header" has "$ROOT/etc/systemd/system/geforce-bar1-resize.service.d/override.conf" "^# Copied by install.sh from /etc/systemd/system/rebar-arm.service.d/override.conf"
	check "new unit enabled (old was)" eq "$(readlink "$ROOT/etc/systemd/system/sysinit.target.wants/geforce-bar1-resize.service")" /etc/systemd/system/geforce-bar1-resize.service
	check "migrated marker" has "$ROOT/etc/geforce-bar1-resize/migrated" "^/etc/rebar-arm.conf$"
	tree_sum "$ROOT" >"$CDIR/tree.1"
	inst; check "second run rc 0" eq "$RC" 0
	check "second run: no migration" hasnt "$CDIR/install.out" "Found an install"
	tree_sum "$ROOT" >"$CDIR/tree.2"
	check "second run: tree byte-identical" same_tree "$CDIR/tree.1" "$CDIR/tree.2"
	boot; check "boot from the migrated config" has "$CDIR/out" "$A armed and resized to 32768 MiB"
	check "console card $C not in the migrated list" eq "$(count $C writes)" 0
}
run_case 71-migrate-enabled "migration: config mapped, P2P key kept, old files moved, unit enabled, idempotent" c71

c72() {
	card $A; old_install 0 "$A"
	inst; check "rc 0" eq "$RC" 0
	check "not enabled (old was not)" absent "$ROOT/etc/systemd/system/sysinit.target.wants/geforce-bar1-resize.service"
	check "no old option file: DRIVER_OPTION=off" has "$ROOT/etc/geforce-bar1-resize.conf" "^DRIVER_OPTION=off$"
	check "no option file" absent "$ROOT/$OPTF"
	check "VRAM unknown note" has "$CDIR/install.out" "VRAM unknown \(driver never seen this card\)"
	check "plan uses SIZE 9 (no record needed)" has "$CDIR/install.out" "$A would arm 0x610 VAL=9"
}
run_case 72-migrate-disabled "migration of a disabled install without the driver option: stays disabled, option off" c72

c73() {
	card $A; smi_for $A:20480
	echo "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMDynBar1P2PEnable=0;\"" >"$ROOT/etc/modprobe.d/p2p.conf"
	inst; check "foreign line: rc 1" eq "$RC" 1
	check "why" has "$CDIR/install.out" "another modprobe.d file sets NVreg_RegistryDwordsPerDevice"
	check "nothing installed" absent "$ROOT/usr/local/sbin/geforce-bar1-resize"
	inst --adopt-driver-line; check "--adopt-driver-line rc 0" eq "$RC" 0
	check "merged" opt_is "pci=$A;RMForceStaticBar1=0;RMDynBar1P2PEnable=0;"
	check "commented out" has "$ROOT/etc/modprobe.d/p2p.conf" "^# adopted by geforce-bar1-resize: "
}
run_case 73-install-foreign-line "a foreign per-device line stops the install; --adopt-driver-line merges it" c73

c74() {
	card $A; card $B
	inst --bdfs "$A" --n 8 --no-lift-ceiling --force --include-console --resize-only; check "rc 0" eq "$RC" 0
	for o in "--bdfs is deprecated; use --cards" "--n is deprecated; use --size" "--no-lift-ceiling is deprecated; use --driver-option off" "--resize-only is deprecated; use --route resize"; do
		check "note: $o" has "$CDIR/install.out" "note: $o"
	done
	check "mapped" eq "$(grep -cE "^(CARDS=$A|SIZE=8|DRIVER_OPTION=off|ROUTE=resize)$" "$ROOT/etc/geforce-bar1-resize.conf")" 4
	inst --layout; check "old --layout: auto + module" has "$ROOT/etc/geforce-bar1-resize.conf" "^LAYOUT=auto$"
	check "module skipped under --root" has "$CDIR/install.out" "skipped: module build and install \(--root\)"
}
run_case 74-install-old-flags "old flags accepted with their replacement printed" c74

c75() {
	card $A; smi_for $A:20480
	RC=0; "$SRC/install.sh" --root "$ROOT" </dev/null >"$CDIR/install.out" 2>&1 || RC=$?
	check "no tty, no --yes: refused" eq "$RC" 1
	check "nothing installed" absent "$ROOT/etc/geforce-bar1-resize.conf"
	inst --dry-run; check "dry run rc 0" eq "$RC" 0
	check "dry run: nothing written" eq "$(find "$ROOT" -type f | wc -l)" 0
	check "dry run: plan and option shown" has "$CDIR/install.out" "options nvidia NVreg_RegistryDwordsPerDevice=\"pci=$A;RMForceStaticBar1=0;\""
}
run_case 75-install-ask-dryrun "without --yes and a tty: refused; --dry-run writes nothing" c75

c76() {
	card $A; card $S1 under="$U1"; smi_for $A:20480 $S1:20480
	inst --enable; old_install 1 "$A"
	mkdir -p "$ROOT/usr/src/geforce-bar1-layout-0.2" "$ROOT/lib/modules/6.12.0-1-amd64/updates/dkms"
	echo x >"$ROOT/lib/modules/6.12.0-1-amd64/updates/dkms/gbr_layout.ko.xz"
	uninst --dry-run; check "dry run rc 0" eq "$RC" 0
	check "dry run removed nothing" present "$ROOT/usr/local/sbin/geforce-bar1-resize"
	uninst; check "rc 0" eq "$RC" 0
	for f in usr/local/sbin/geforce-bar1-resize etc/systemd/system/geforce-bar1-resize.service etc/systemd/system/geforce-bar1-resize-record@.service etc/udev/rules.d/90-geforce-bar1-resize.rules etc/geforce-bar1-resize.conf etc/geforce-bar1-resize "$OPTF" etc/systemd/system/sysinit.target.wants/geforce-bar1-resize.service usr/src/geforce-bar1-layout-0.2 lib/modules/6.12.0-1-amd64/updates/dkms/gbr_layout.ko.xz $OLDS; do
		check "removed /$f" absent "$ROOT/$f"
	done
	check "warns BAR1 stays large" has "$CDIR/uninstall.out" "BAR1 IS STILL LARGE"
	check "notes the driver option" has "$CDIR/uninstall.out" "RMForceStaticBar1=0 stays active"
}
run_case 76-uninstall "uninstall removes new and old names (half-migrated host)" c76

c77() {
	card $S1 under="$U1" fail=nospc; smi_for $S1:20480
	inst; check "switch note with LAYOUT=off" has "$CDIR/install.out" "note: behind a PCIe switch: $S1"
	inst --layout auto; check "auto: module wanted" has "$CDIR/install.out" "Layout module gbr_layout"
	inst --layout off --layout-module; check "--layout-module builds anyway" has "$CDIR/install.out" "skipped: module build and install \(--root\)"
}
run_case 77-install-switch "card behind a switch: note; --layout auto or --layout-module builds the module" c77

c78() {
	# uninstall.sh (live, not --root) while a record unit waits RECORD_DELAY for a card it has no record of: the udev
	# rule goes and udev reloads first, then the unit is stopped before any other file goes, so it never wakes to write
	# the record and the driver option file back. uninstall.sh runs as a copy whose absolute paths point below $ROOT
	# ($ROOT itself stays empty); systemctl and udevadm are case stubs that log each call with what is still installed.
	card $A bound=1
	inst; check "install rc 0" eq "$RC" 0
	check "driver not loaded at install: no record" absent "$ROOT/etc/geforce-bar1-resize/vram"
	smi_for $A:20480
	printf 'RECORD_DELAY=5\nLOG=%s\n' "$CDIR/unit.log" >>"$ROOT/etc/geforce-bar1-resize.conf"
	local rule=$ROOT/etc/udev/rules.d/90-geforce-bar1-resize.rules sbin=$ROOT/usr/local/sbin/geforce-bar1-resize unit t
	# shellcheck disable=SC2046 # word list of assignments
	env $(GBR_ENV) LD_PRELOAD="$BIN/standin-open.so" "$sbin" record --delay $A >"$CDIR/unit.out" 2>&1 &
	unit=$!
	mkdir -p "$CDIR/stub"
	for t in systemctl udevadm; do
		cat >"$CDIR/stub/$t" <<-EOF
			#!/bin/sh
			echo "$t \$* | rule \$([ -e '$rule' ] && echo present || echo gone) | script \$([ -e '$sbin' ] && echo present || echo gone)" >>'$CDIR/calls'
			[ "\$1 \$2" != 'stop geforce-bar1-resize-record@*.service' ] || { pkill -P $unit; kill $unit; } 2>/dev/null
			exit 0
		EOF
		chmod 755 "$CDIR/stub/$t"
	done
	sed -e "s#\\([\"( $(printf '\t')]\\)/\\(etc\\|usr\\|var\\|lib\\|run\\)/#\\1$ROOT/\\2/#g" -e "s#\\\$ROOT/#$ROOT/#g" \
		"$SRC/uninstall.sh" >"$CDIR/uninstall-live.sh"
	chmod 755 "$CDIR/uninstall-live.sh"
	check "live copy: every system path below \$ROOT" hasnt "$CDIR/uninstall-live.sh" "[\"( $(printf '\t')]/(etc|usr|var|lib|run)/"
	RC=0; PATH="$CDIR/stub:$PATH" "$CDIR/uninstall-live.sh" >"$CDIR/uninstall.out" 2>&1 || RC=$?
	sed 's/^/  | /' "$CDIR/uninstall.out" >>"$LOG"; echo "  rc=$RC" >>"$LOG"
	wait $unit 2>/dev/null
	sed 's/^/  > /' "$CDIR/calls" >>"$LOG"
	check "uninstall rc 0" eq "$RC" 0
	check "udev reloaded after the rule is gone, while the script is still there" has "$CDIR/calls" '^udevadm control --reload \| rule gone \| script present$'
	check "then the waiting record unit is stopped, before the script goes" has "$CDIR/calls" '^systemctl stop geforce-bar1-resize-record@\*\.service \| rule gone \| script present$'
	check "reload before stop" before "$CDIR/calls" '^udevadm control --reload' '^systemctl stop geforce-bar1-resize-record@'
	check "the unit never queried the card" absent "$FAKE/smi.calls"
	check "no record written back" absent "$ROOT/etc/geforce-bar1-resize"
	check "no driver option file written back" absent "$ROOT/$OPTF"
	for t in "$sbin" "$rule" "$ROOT/etc/geforce-bar1-resize.conf"; do check "removed ${t#"$ROOT"}" absent "$t"; done
}
run_case 78-uninstall-record-wait "uninstall while a record unit waits: rule gone, udev reloaded, unit stopped first; nothing written back" c78
