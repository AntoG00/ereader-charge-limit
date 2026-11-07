#!/bin/sh
# Keeps the battery between RESUME and LIMIT percent while plugged in: at
# LIMIT charging is switched off and the reader runs from USB. On a reader
# chargectl can't control, it only saves diagnostics and idles.

DIR=$(cd "$(dirname "$0")" && pwd)
CHG=$DIR/chargectl
WAKEALARM=/sys/class/rtc/rtc0/wakealarm
LOG=/tmp/chargelimit.log
# Plain-language events for the activity view.
ACTIVITY=/tmp/chargelimit-activity.log
LOCK=/tmp/chargelimitd.lock
# START has been applied this boot.
BOOTED=/tmp/chargelimit.booted

. "$DIR/platform.sh"

# Until the config is first read.
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

# launch.sh sends USR1 to ask for a check now: it ends the nap, and one that
# arrives during a check skips the next nap.
poked=
trap 'poked=1' USR1
nap() {
	if [ -n "$poked" ]; then
		poked=
		return
	fi
	sleep "$POLL" &
	wait $!
	kill $! 2>/dev/null
	poked=
}

# The guided report (support.sh) switches charging itself and starts us
# again when it's done.
spid=$(cat /tmp/chargelimit-support/pid 2>/dev/null)
[ -n "$spid" ] && kill -0 "$spid" 2>/dev/null && exit 0

# One daemon at a time. Several udev events can start us at once at boot, so
# give the winner a moment to write its pid before calling the lock stale.
if ! mkdir "$LOCK" 2>/dev/null; then
	sleep 1
	kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null && exit 0
fi
echo $$ > "$LOCK/pid"
# launch.sh restarts a daemon whose version is no longer the installed one.
cp "$DIR/VERSION" "$LOCK/version"

# Hand charging back to the stock driver if we're killed.
stop() {
	"$CHG" on
	rm -rf "$LOCK"
	log "stopped"
	exit 0
}
trap stop TERM INT

while :; do
	# Storage can be missing (USB mode on a Kobo, early boot): keep the last
	# settings, and do nothing before the first read.
	if storage_ready; then
		# First read: create the config, apply START once per boot, and
		# write the menu.
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

	# Diagnostics once per run, and on DIAGNOSE=1: on a reader we can't
	# control, the guided report (a Kobo without NickelMenu has no menu to
	# start it from). The once-per-run report doesn't replace a guided one.
	if storage_ready && { [ -z "$diag_saved" ] || [ "$DIAGNOSE" = 1 ]; }; then
		mkdir -p "$USER_DIR"
		if [ "$DIAGNOSE" = 1 ] && ! "$CHG" status >/dev/null 2>&1; then
			set_setting DIAGNOSE 0
			sh "$DIR/support.sh" tap >/dev/null
		elif [ "$DIAGNOSE" = 1 ] ||
			! grep -q '^Charge Limit support report' "$USER_DIR/diagnostics.log" 2>/dev/null; then
			"$DIR/diagnostics.sh" > "$USER_DIR/diagnostics.log" 2>&1
		fi
		[ "$DIAGNOSE" = 1 ] && set_setting DIAGNOSE 0
		diag_saved=1
	fi

	# Unsupported reader: log it once, then idle.
	if ! status=$("$CHG" status 2>>"$LOG"); then
		if [ -z "$unavailable" ]; then
			eval "$status"
			log "no usable charge control (method=$method, pmic=$pmic), idling; see $USER_DIR/diagnostics.log"
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

	# A gap longer than POLL means the reader slept.
	now=$(date +%s)
	if [ -n "$last" ] && [ $((now - last)) -gt $((POLL + 10)) ]; then
		log "check after $((now - last)) s asleep: battery ${cap}% ${voltage_uv}uV, charging_enabled=$charging_enabled, plugged=$plugged"
	fi
	last=$now

	# Charging stays on from an unplug to the next plug-in, which covers
	# readers that report charging_enabled=unknown while unplugged.
	if [ "$plugged" = 1 ]; then
		on_since_unplug=
	elif [ -n "$on_since_unplug" ]; then
		charging_enabled=1
	fi

	# A full charge ends at the first unplug after a plug-in, so one set
	# while unplugged waits for the next charge.
	if [ "$FULL_CHARGE" != 1 ]; then
		full_plugged=
	elif [ "$plugged" = 1 ]; then
		full_plugged=1
	elif [ -n "$full_plugged" ] && set_setting FULL_CHARGE 0; then
		full_plugged=
		"$DIR/actions.sh" menu
	fi

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

	# Between RESUME and LIMIT, keep the current state.
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

	shown="$ENABLED $LIMIT $START $FULL_CHARGE $plugged $charging_enabled $cap"
	if [ "$shown" != "$last_shown" ]; then
		# The app may already be open when the daemon applies START at boot.
		notify_ui
		last_shown=$shown
	fi

	# While charging towards LIMIT, a wake alarm brings a sleeping reader back
	# to check. Each wake-up clears it; set only when none is pending, to
	# leave the system's own alone.
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
