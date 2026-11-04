#!/bin/sh
# Keep a reader's battery between RESUME and LIMIT percent while plugged in.
# At LIMIT charging is switched off and the reader runs from USB. chargectl
# works out how this reader's charging can be controlled; on a reader where it
# can't, the daemon only writes diagnostics and idles. It keeps running while
# the limit is off (ENABLED=0), only making sure charging is on, so turning
# it back on in the config applies within POLL seconds. What differs between
# readers (paths, menu, uninstall) comes from platform.sh.

DIR=$(cd "$(dirname "$0")" && pwd)
CHG=$DIR/chargectl
WAKEALARM=/sys/class/rtc/rtc0/wakealarm
# Full technical log, for diagnostics and reports.
LOG=/tmp/chargelimit.log
# A few plain-language events for the menu's activity view (actions.sh).
ACTIVITY=/tmp/chargelimit.activity
LOCK=/tmp/chargelimitd.lock
# Created once START has been applied this boot; /tmp is cleared on reboot.
BOOTED=/tmp/chargelimit.booted

. "$DIR/platform.sh"

# The settings come from settings.sh, re-sourced every check; this is only
# for the checks before the config is first readable.
POLL=30

log() {
	[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && : > "$LOG"
	echo "$(date '+%F %T') $*" >> "$LOG"
}

activity() {
	[ -f "$ACTIVITY" ] && [ "$(wc -l < "$ACTIVITY")" -gt 40 ] &&
		tail -n 20 "$ACTIVITY" > "$ACTIVITY.tmp" && mv "$ACTIVITY.tmp" "$ACTIVITY"
	echo "$(date '+%H:%M') $*" >> "$ACTIVITY"
}

# launch.sh sends USR1 on every power_supply event to ask for an immediate
# check. Trap it before anything else: its default action would kill us. A
# trapped signal makes `wait` return early, which ends the nap.
trap : USR1
nap() {
	sleep "$POLL" &
	wait $!
	kill $! 2>/dev/null
}

# One daemon per boot. /tmp is a tmpfs, so a lock left by a crash is gone after
# a reboot; until then the pid check below catches it. At boot several udev
# events can start us at once, and the winner may not have written its pid
# yet, so give it a moment before treating the lock as stale.
if ! mkdir "$LOCK" 2>/dev/null; then
	sleep 1
	kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null && exit 0
fi
echo $$ > "$LOCK/pid"

# Hand charging back to the stock driver if we're killed.
stop() {
	"$CHG" on
	rm -rf "$LOCK"
	log "stopped"
	exit 0
}
trap stop TERM INT

while :; do
	# The user's storage can be unavailable, for example on a Kobo in USB
	# mass-storage mode; the last settings read stay in effect until it's
	# back. At boot it may not be mounted yet, and ENABLED isn't known until
	# it is, so wait for the first read before doing anything.
	if storage_ready; then
		# Once per run: give users a commented config to find and edit,
		# apply START once per boot (the marker stops a daemon restarted
		# later in the same boot from applying it again), and refresh the
		# menu.
		if [ -z "$config_read" ]; then
			if [ ! -f "$USER_DIR/config" ]; then
				mkdir -p "$USER_DIR"
				cp "$DIR/config.default" "$USER_DIR/config"
			fi
			. "$DIR/settings.sh"
			if [ ! -e "$BOOTED" ]; then
				[ "$ENABLED" = "$START" ] || set_setting ENABLED "$START"
				: > "$BOOTED"
			fi
			"$DIR/actions.sh" menu
		fi
		. "$DIR/settings.sh"
		config_read=1
	elif [ -z "$config_read" ]; then
		nap
		continue
	fi
	if [ "$UNINSTALL" = 1 ]; then
		"$CHG" on
		platform_uninstall
		rm -rf "$USER_DIR" "$DIR" "$LOCK" "$BOOTED"
		log "uninstalled"
		exit 0
	fi

	# Diagnostics go to the user's storage once per boot, and again whenever
	# the user sets DIAGNOSE=1.
	if storage_ready && { [ -z "$diag_saved" ] || [ "$DIAGNOSE" = 1 ]; }; then
		mkdir -p "$USER_DIR"
		"$DIR/diagnostics.sh" > "$USER_DIR/diagnostics.txt" 2>&1
		[ "$DIAGNOSE" = 1 ] && set_setting DIAGNOSE 0
		diag_saved=1
	fi

	# Exits non-zero when this reader has no usable charge control; it still
	# prints what it found. Log that once, then idle.
	if ! status=$("$CHG" status 2>>"$LOG"); then
		if [ -z "$unavailable" ]; then
			eval "$status"
			log "no usable charge control (method=$method, pmic=$pmic), idling; see $USER_DIR/diagnostics.txt"
			activity "This reader isn't supported yet"
			unavailable=1
		fi
		nap
		continue
	fi
	eval "$status"
	if [ -z "$announced" ]; then
		log "started, version $(cat "$DIR/VERSION" 2>/dev/null): method=$method pmic=$pmic battery=$battery"
		announced=1
	elif [ -n "$unavailable" ]; then
		log "using method=$method pmic=$pmic battery=$battery"
	fi
	unavailable=
	cap=$capacity

	# Awake, checks are at most POLL seconds apart, so a longer gap means the
	# reader slept. Log what this first check after waking sees, to show
	# whether the battery reading is fresh (voltage moves even if % doesn't).
	now=$(date +%s)
	if [ -n "$last" ] && [ $((now - last)) -gt $((POLL + 10)) ]; then
		log "check after $((now - last)) s asleep: battery ${cap}% ${voltage_uv}uV, charging_enabled=$charging_enabled, plugged=$plugged"
	fi
	last=$now

	# Nothing switches charging off while unplugged, so once it's on after an
	# unplug it stays on until the next plug-in. That covers readers where
	# chargectl can't read the state while unplugged (charging_enabled=unknown).
	if [ "$plugged" = 1 ]; then
		on_since_unplug=
	elif [ -n "$on_since_unplug" ]; then
		charging_enabled=1
	fi

	# A full charge lasts until the charger is unplugged: it ends at the first
	# check that sees the charger gone after seeing it plugged in, so one set
	# while unplugged covers the next time it's plugged in. Retried if the
	# config can't be written yet (USB mass-storage mode).
	if [ "$FULL_CHARGE" != 1 ]; then
		full_plugged=
	elif [ "$plugged" = 1 ]; then
		full_plugged=1
	elif [ -n "$full_plugged" ] && set_setting FULL_CHARGE 0; then
		full_plugged=
		"$DIR/actions.sh" menu
	fi

	# Only "limiting" holds the battery below 100%. Each change is reported
	# once, whether it came from the menu, the config or the daemon itself.
	limiting=
	if [ "$ENABLED" = 0 ]; then
		mode="limit off"
	elif [ "$FULL_CHARGE" = 1 ]; then
		mode="full charge until unplugged"
	else
		mode="limit $LIMIT%"
		limiting=1
	fi
	if [ "$mode" != "$last_mode" ]; then
		log "$mode"
		if [ -n "$limiting" ]; then
			activity "Charge limit on ($LIMIT%)"
		elif [ "$ENABLED" = 0 ]; then
			activity "Charge limit off"
		else
			activity "Charging to 100% until unplugged"
		fi
		last_mode=$mode
	fi

	# Between RESUME and LIMIT keep the current state, so the stock driver
	# re-enabling charging there just tops the battery up to LIMIT.
	want=$charging_enabled
	if [ "$plugged" = 0 ] || [ -z "$limiting" ]; then
		want=1
	elif [ "$cap" -ge "$LIMIT" ]; then
		want=0
	elif [ "$cap" -le "$RESUME" ]; then
		want=1
	fi

	if [ "$want" != "$charging_enabled" ]; then
		if [ "$want" = 1 ]; then action=on; else action=off; fi
		if "$CHG" "$action" 2>>"$LOG"; then
			log "charging $action (battery ${cap}%, plugged=$plugged)"
			if [ "$want" = 0 ]; then
				activity "Stopped charging at $cap%"
			elif [ "$plugged" = 1 ]; then
				activity "Resumed charging at $cap%"
			else
				activity "Unplugged at $cap%, charging allowed again"
			fi
			charging_enabled=$want
		fi
	fi
	[ "$plugged" = 0 ] && [ "$charging_enabled" = 1 ] && on_since_unplug=1

	# The PMIC keeps charging while the reader sleeps and this loop can't run,
	# so while we're letting it charge towards LIMIT, a wake alarm brings the
	# reader back to check (the wake-up's power_supply event makes launch.sh
	# signal us). This is a fallback: the Sage wakes itself about every 87 s
	# while plugged in, which comes first, and every wake-up clears the alarm,
	# so it's set again after each one. With charging off the battery can't
	# climb, and without the limit there's nothing to stop, so no alarm is
	# needed. Only set when no alarm is pending, to leave the system's own alone.
	if [ "$WAKE_WHILE_CHARGING" = 1 ] && [ -n "$limiting" ] && [ "$plugged" = 1 ] &&
	   [ "$want" = 1 ] && [ -z "$(cat "$WAKEALARM" 2>/dev/null)" ]; then
		if (echo "+$WAKE_INTERVAL" > "$WAKEALARM") 2>/dev/null; then
			log "wake alarm set for +$WAKE_INTERVAL s (battery ${cap}%)"
		else
			log "could not set wake alarm"
		fi
	fi

	nap
done
