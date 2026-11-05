#!/bin/sh
# The guided report for a reader Charge Limit can't control yet, started by
# "Charge diagnostics" there. The user unplugs, plugs in a wall charger and
# unplugs again; it records what's needed to add the reader in one go:
#   - the diagnostics, and every attribute of the power devices unplugged,
#     plugged in and unplugged again, with what changed (the plug signal)
#     and the kernel events each time (how power events arrive);
#   - a switch test while plugged in: each candidate is switched for about
#     40 s while the battery current is sampled, then put back. Candidates
#     are known switches with their known values, and writable 0/1
#     attributes named like a charge enable that are on (only ever switched
#     off). A watchdog puts every value back if the test dies.
# The result replaces diagnostics.log.
#
#   support.sh tap       start a run, or say how far it is
#   support.sh progress  "running", "done" or "idle", then the text
#   support.sh run DIR   the run itself: tap starts a copy in $W, since a
#                        Kindle runs this from user storage before
#                        installing, which USB mode unmounts

DIR=$(cd "$(dirname "$0")" && pwd)
[ "$1" = run ] && DIR=$2
. "$DIR/platform.sh"
W=/tmp/chargelimit-support
# How long a finished run's result is shown; a tap after that starts again.
SHOWN=600
MAX_SWITCHES=8
TAB=$(printf '\t')

now() {
	date +%s
}

# The current step, for tap and progress, and its first line in the steps log.
say() {
	printf '%s\n' "$*" > "$W/state.tmp" && mv "$W/state.tmp" "$W/state"
	echo "$(date +%T) $(printf '%s\n' "$*" | head -n 1)" >> "$W/steps"
}

note() {
	echo "$(date +%T) note: $*" >> "$W/steps"
}

running() {
	[ -f "$W/pid" ] && kill -0 "$(cat "$W/pid")" 2>/dev/null
}

recently_done() {
	[ -f "$W/done" ] && [ $(($(now) - $(cat "$W/done"))) -lt "$SHOWN" ]
}

intro() {
	cat <<EOF
This reader isn't supported yet. A short test, about 5 minutes, collects what's needed to add it. It needs a wall charger, not a computer. Charge Limit switches charging off and on a few times; charging always comes back on. At the end it saves ${USER_DIR##*/}/diagnostics.log to send with your request.
EOF
}

# The steps, as the user sees them: what to do now, and what comes next.
STEP1="Step 1 of 4
Now: unplug the charger, if it's plugged in.
Next: plug in a wall charger."
STEP2="Step 2 of 4
Now: plug in a wall charger (not a computer) and leave it plugged in.
Next: Charge Limit tests the charging for a few minutes."
STEP4="Step 4 of 4
Now: unplug the charger.
Next: the report is saved."

# step3 I N: the switch test's step.
step3() {
	cat <<EOF
Step 3 of 4: testing, switch $1 of $2, about $(($2 - $1 + 1)) min left
Now: leave it plugged in. Charging goes off and on; it always comes back on.
Next: unplug when it says so.
EOF
}

# For the Kindle app, which shows it by itself every 5 s.
progress() {
	if running; then
		echo running
		cat "$W/state"
		echo
		intro
	elif recently_done; then
		echo done
		cat "$W/summary"
	else
		echo idle
	fi
}

# For a tap on Charge diagnostics: the Kobo's menu shows one answer per tap.
tap() {
	if running; then
		cat "$W/state"
		echo
		echo "Tap Charge diagnostics again to see the next step."
		return
	fi
	if recently_done; then
		cat "$W/summary"
		return
	fi
	rm -rf "$W"
	mkdir -p "$W"
	echo "$STEP1" > "$W/state"
	cp "$DIR/support.sh" "$W/support.sh"
	setsid sh "$W/support.sh" run "$DIR" </dev/null >/dev/null 2>&1 &
	echo $! > "$W/pid"
	intro
	echo
	echo "$STEP1"
	echo
	echo "After each step, tap Charge diagnostics again to see the next one."
}

# The battery's power_supply folder.
find_battery() {
	for s in /sys/class/power_supply/*; do
		[ "$(cat "$s/type" 2>/dev/null)" = Battery ] && echo "$s" && return
	done
}

on_battery() {
	[ "$(cat "$battery/status" 2>/dev/null)" = Discharging ]
}

# wait_for unplugged|plugged SECONDS
wait_for() {
	n=0
	while [ "$n" -lt "$2" ]; do
		if on_battery; then
			[ "$1" = unplugged ] && return 0
		else
			[ "$1" = plugged ] && return 0
		fi
		sleep 2
		n=$((n + 2))
	done
	return 1
}

# Kernel events during a step: how plugging in reaches udev rules.
events() {
	if [ "$1" = start ]; then
		udevadm monitor --kernel > "$W/events.$2" 2>&1 &
		echo $! > "$W/events.pid"
	else
		kill "$(cat "$W/events.pid" 2>/dev/null)" 2>/dev/null
		rm -f "$W/events.pid"
	fi
}

# Where a power switch can be: each power_supply, its device, the device's
# parent (the power chip) and the parent's other devices, and Lab126-style
# system devices.
#
#   /sys/devices/platform/imx-i2c.0/i2c-0/0-003c
#   /sys/devices/platform/imx-i2c.0/i2c-0/0-003c/max77696-battery.0
#   /sys/devices/platform/imx-i2c.0/i2c-0/0-003c/max77696-charger.0
#   /sys/devices/system/wario_charger/wario_charger0
power_dirs() {
	{
		for s in /sys/class/power_supply/*; do
			[ -e "$s" ] || continue
			readlink -f "$s"
			d=$(readlink -f "$s/device")
			[ -d "$d" ] || continue
			echo "$d"
			echo "${d%/*}"
			for c in "${d%/*}"/*; do
				[ -d "$c" ] && [ ! -L "$c" ] && echo "$c"
			done
		done
		for c in /sys/devices/system/*charg*/* /sys/devices/system/*batt*/*; do
			[ -d "$c" ] && [ ! -L "$c" ] && echo "$c"
		done
	} | sort -u
}

# Every attribute of those folders, "path<TAB>value", one line each.
snapshot() {
	while read -r d; do
		for f in "$d"/*; do
			[ -f "$f" ] && [ ! -L "$f" ] || continue
			case ${f##*/} in
			uevent | modalias) continue ;;
			esac
			v=$(head -c 100 "$f" 2>/dev/null | tr '\t\r\000' '   ')
			printf '%s\t%s\n' "$f" "$(printf %s "$v" | tr '\n' ' ')"
		done
	done < "$W/dirs"
}

# changes A B: the attributes whose value differs.
changes() {
	if [ ! -f "$W/$1" ] || [ ! -f "$W/$2" ]; then
		echo "(not recorded)"
		return
	fi
	awk -F'\t' 'NR == FNR { old[$1] = $2; next }
		($1 in old) && old[$1] != $2 { print $1 ": " old[$1] " -> " $2 }' "$W/$1" "$W/$2"
}

# "path<TAB>value that stops charging<TAB>value that charges", known ones
# first. Only switches that are on now; generic ones are only switched off.
candidates() {
	wario=/sys/devices/system/wario_charger/wario_charger0/mode
	[ "$(cat "$wario" 2>/dev/null)" = 5 ] && printf '%s\t4\t5\n' "$wario"
	# Mainline Linux: "[auto] inhibit-charge force-discharge".
	for f in /sys/class/power_supply/*/charge_behaviour; do
		case $(cat "$f" 2>/dev/null) in
		*"[auto]"*inhibit-charge*) printf '%s\tinhibit-charge\tauto\n' "$(readlink -f "$f")" ;;
		esac
	done
	cut -f1 "$W/b" | while read -r f; do
		name=${f##*/}
		case $name in
		*otg* | *boost* | *volt* | *curr* | *limit* | *temp* | *time* | *det* | *debounce* | *thr* | *wdt* | *led* | charge_behaviour) continue ;;
		*charg* | *chg*) ;;
		*) continue ;;
		esac
		[ "$f" = "$wario" ] && continue
		[ "$(cat "$f" 2>/dev/null)" = 1 ] || continue
		case $(ls -l "$f") in
		??w*) printf '%s\t0\t1\n' "$f" ;;
		esac
	done
}

# The plug signals: online/present/connected attributes that changed when
# the charger was plugged in, with their plugged-in value. Charging off can
# make the battery read Discharging, so these tell an unplug apart.
find_plug_signals() {
	changes a b | while read -r f old arrow new; do
		case ${f%:} in
		*/online | */present | */connected) printf '%s\t%s\n' "${f%:}" "$new" ;;
		esac
	done > "$W/plug"
}

still_plugged() {
	if [ ! -s "$W/plug" ]; then
		! on_battery
		return
	fi
	while IFS=$TAB read -r f v; do
		[ "$(cat "$f" 2>/dev/null)" = "$v" ] && return 0
	done < "$W/plug"
	return 1
}

current() {
	cat "$battery/current_now" 2>/dev/null || echo 0
}

# The mean of N readings 3 s apart.
mean_current() {
	sum=0
	k=0
	while [ "$k" -lt "$1" ]; do
		[ "$k" -gt 0 ] && sleep 3
		sum=$((sum + $(current)))
		k=$((k + 1))
	done
	echo $((sum / $1))
}

# Put back every switched value still listed; the watchdog runs it if the
# run dies mid-test.
restore_all() {
	[ -s "$W/restore" ] || return 0
	while IFS=$TAB read -r f v; do
		echo "$v" > "$f"
	done < "$W/restore"
	echo "$(date +%T) restored: $(cut -f1 "$W/restore" | tr '\n' ' ')" >> "$W/steps"
	: > "$W/restore"
}

# test_switch PATH OFF ON: the effect on the battery current, relative to
# charging before (units differ by driver; positive is charging).
test_switch() {
	f=$1
	before=$(mean_current 3)
	v0=$(cat "$battery/voltage_now" 2>/dev/null)
	printf '%s\t%s\n' "$f" "$3" >> "$W/restore"
	echo "$2" > "$f" 2>/dev/null
	set_to=$(cat "$f" 2>/dev/null)
	readings=
	k=0
	while [ "$k" -lt 6 ]; do
		sleep 5
		readings="$readings $(current)/$(cat "$battery/status" 2>/dev/null)"
		k=$((k + 1))
	done
	during=$(mean_current 3)
	v1=$(cat "$battery/voltage_now" 2>/dev/null)
	echo "$3" > "$f"
	back=$(cat "$f" 2>/dev/null)
	grep -v "^$f$TAB" "$W/restore" > "$W/restore.tmp"
	mv "$W/restore.tmp" "$W/restore"
	sleep 10
	after=$(mean_current 3)

	if [ $((during * 100)) -le $((before * 15)) ] && [ $((during * 100)) -ge $((-before * 15)) ]; then
		effect="stops charging, the reader runs from the charger"
	elif [ $((during * 100)) -lt $((-before * 15)) ]; then
		effect="stops charging, but the reader runs from its battery"
	elif [ $((during * 100)) -ge $((before * 60)) ]; then
		effect="no effect"
	else
		effect="reduces charging"
	fi
	if [ $((after * 100)) -ge $((before * 50)) ]; then
		restored="charging came back"
	else
		restored="charging did NOT fully come back"
		weak=$before
	fi
	echo "${f##*/}: $effect" >> "$W/verdicts"
	echo "$f"
	echo "  set to $2 (reads $set_to), back to $3 (reads $back)"
	echo "  current: before $before, during $during, after $after ($restored)"
	echo "  voltage: before $v0, during $v1"
	echo "  readings every 5 s:$readings"
	echo "  => $effect"
}

switch_test() {
	candidates > "$W/found"
	# About a minute each: at most MAX_SWITCHES (known ones come first), so
	# the README's 10 minutes plugged in always cover it.
	head -n "$MAX_SWITCHES" "$W/found" > "$W/candidates"
	total=$(grep -c '' "$W/candidates")
	: > "$W/restore"
	if [ "$total" = 0 ]; then
		echo "No candidate switches found." > "$W/switch"
		return
	fi
	before=$(mean_current 3)
	if [ "$before" -le 0 ]; then
		{
			echo "Not tested: the battery wasn't charging (current $before, status $(cat "$battery/status" 2>/dev/null))."
			echo "Run it again with the battery below 90%. Candidates:"
			cut -f1 "$W/candidates"
		} > "$W/switch"
		return
	fi
	main=$$
	(
		while kill -0 "$main" 2>/dev/null; do
			sleep 2
		done
		restore_all
	) </dev/null >/dev/null 2>&1 &
	: > "$W/switch"
	i=0
	while IFS=$TAB read -r f off on; do
		i=$((i + 1))
		say "$(step3 "$i" "$total")"
		weak=
		test_switch "$f" "$off" "$on" >> "$W/switch"
		if ! still_plugged; then
			echo "Stopped: the charger was unplugged." >> "$W/switch"
			break
		fi
		[ -n "$weak" ] || continue
		# Charging didn't come back: every switch's charging value again.
		while IFS=$TAB read -r g goff gon; do
			echo "$gon" > "$g"
		done < "$W/candidates"
		sleep 10
		again=$(mean_current 3)
		echo "  wrote every switch's charging value again: current $again" >> "$W/switch"
		if [ $((again * 100)) -lt $((weak * 50)) ]; then
			echo "Stopped: charging didn't come back on." >> "$W/switch"
			: > "$W/stuck"
			break
		fi
	done < "$W/candidates"
}

report() {
	echo "Charge Limit support report"
	echo "version: $version"
	echo "date: $(date '+%F %T %Z')"
	echo
	echo "== steps =="
	cat "$W/steps"
	echo
	echo "== switch test =="
	cat "$W/switch" 2>/dev/null || echo "(not run)"
	if [ -f "$W/found" ] && [ "$(grep -c '' "$W/found")" -gt "$MAX_SWITCHES" ]; then
		echo "Not tested (over $MAX_SWITCHES):"
		tail -n +$((MAX_SWITCHES + 1)) "$W/found" | cut -f1
	fi
	echo
	echo "== plugging in: what changed =="
	changes a b
	echo
	echo "== plug signals (used to tell an unplug apart) =="
	tr '\t' '=' < "$W/plug" 2>/dev/null
	echo
	echo "== plugging in: kernel events =="
	cat "$W/events.plug" 2>/dev/null || echo "(not recorded)"
	echo
	echo "== unplugging: what changed =="
	changes b c
	echo
	echo "== unplugging: kernel events =="
	cat "$W/events.unplug" 2>/dev/null || echo "(not recorded)"
	for s in "a unplugged" "b plugged in" "c unplugged again"; do
		echo
		echo "== power devices, ${s#* } =="
		[ -f "$W/${s%% *}" ] && tr '\t' '=' < "$W/${s%% *}" || echo "(not recorded)"
	done
	echo
	cat "$W/diagnostics"
}

run() {
	echo $$ > "$W/pid"
	# Everything from $DIR is read now, while storage is there.
	version=$(cat "$DIR/VERSION" 2>/dev/null)
	# Before stopping a daemon, so its state is in the report.
	sh "$DIR/diagnostics.sh" > "$W/diagnostics" 2>&1
	# On a supported reader (the dev test) the daemon would undo the switch
	# test: stop it; it doesn't start again while this runs (our pid file)
	# and is started again at the end. On an unsupported one it only idles.
	daemon=$(cat /tmp/chargelimitd.lock/pid 2>/dev/null)
	if [ -n "$daemon" ] && grep -q chargelimitd "/proc/$daemon/cmdline" 2>/dev/null &&
		"$DIR/chargectl" status >/dev/null 2>&1; then
		kill "$daemon"
		n=0
		while [ -d /tmp/chargelimitd.lock ] && [ "$n" -lt 10 ]; do
			sleep 1
			n=$((n + 1))
		done
		note "stopped the daemon for the test"
	else
		daemon=
	fi
	battery=$(find_battery)
	power_dirs > "$W/dirs"

	say "$STEP1"
	wait_for unplugged 300 || note "still plugged in after 5 minutes"
	snapshot > "$W/a"

	events start plug
	say "$STEP2"
	if wait_for plugged 600; then
		say "Step 2 of 4
Now: the charger is plugged in; leave it. The test starts in about 30 seconds.
Next: Charge Limit tests the charging for a few minutes."
		sleep 15
		events stop
		snapshot > "$W/b"
		find_plug_signals
		switch_test
		events start unplug
		say "$STEP4"
		wait_for unplugged 1800 || note "not unplugged within 30 minutes"
		# The charger's own events can come seconds after the battery's.
		sleep 15
		events stop
		snapshot > "$W/c"
	else
		events stop
		note "no charger plugged in within 10 minutes"
	fi

	say "Saving the report...
Next: done in a few seconds."
	report > "$W/report" 2>&1
	n=0
	while ! storage_ready && [ "$n" -lt 300 ]; do
		sleep 2
		n=$((n + 2))
	done
	mkdir -p "$USER_DIR" && cp "$W/report" "$USER_DIR/diagnostics.log"
	{
		echo "Done. The report is saved as ${USER_DIR##*/}/diagnostics.log: connect the reader to a computer and attach it to your request."
		[ -f "$W/stuck" ] &&
			echo "Charging may not have come back on: restart the reader to be sure."
		if [ -s "$W/verdicts" ]; then
			echo
			echo "Switch test:"
			cat "$W/verdicts"
		elif [ -f "$W/switch" ]; then
			echo
			head -n 2 "$W/switch"
		fi
	} > "$W/summary"
	now > "$W/done"
	rm -f "$W/pid"
	[ -n "$daemon" ] && [ -f "$DIR/launch.sh" ] && sh "$DIR/launch.sh"
}

case $1 in
tap) tap ;;
progress) progress ;;
run) run ;;
esac
