#!/bin/sh
# Keep a Kobo's battery between RESUME and LIMIT percent while plugged in. At
# LIMIT charging is switched off and the reader runs from USB. kobo-chg works
# out how this reader's charging can be controlled; on a reader where it
# can't, the daemon only writes diagnostics and idles.

DIR=/usr/local/chargelimit
CHG=$DIR/kobo-chg
USER_DIR=/mnt/onboard/.adds/chargelimit
WAKEALARM=/sys/class/rtc/rtc0/wakealarm
LOG=/tmp/chargelimit.log
LOCK=/tmp/chargelimitd.lock
# "started" or "stopped", written by the Start/Stop menu items. /tmp is
# cleared on reboot, so this only lasts until then.
STATE=/tmp/chargelimit.state

# Defaults; $USER_DIR/config may override any of these.
# START=boot limits from boot; START=manual leaves the reader stock until
# the user starts the limiter from the menu.
START=boot
ENABLED=1
LIMIT=80
RESUME=75
POLL=30
WAKE_WHILE_CHARGING=1
WAKE_INTERVAL=120

log() {
	[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ] && : > "$LOG"
	echo "$(date '+%F %T') $*" >> "$LOG"
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

# Hand charging back to the stock driver whenever we stop. An empty message
# stops quietly.
stop() {
	"$CHG" on
	rm -rf "$LOCK"
	[ -n "$1" ] && log "$1"
	exit 0
}
trap 'stop stopped' TERM INT

while :; do
	# The user partition is unmounted while the reader is in USB mass-storage
	# mode (.kobo is missing then); the last settings read stay in effect
	# until it's back. At boot it may not be mounted yet, and START isn't
	# known until it is, so wait for the first read before doing anything.
	if [ -d /mnt/onboard/.kobo ]; then
		[ -f "$USER_DIR/config" ] && . "$USER_DIR/config"
		config_read=1
	elif [ -z "$config_read" ]; then
		nap
		continue
	fi
	if [ -f "$USER_DIR/uninstall" ]; then
		"$CHG" on
		rm -f /etc/udev/rules.d/99-chargelimit.rules "$USER_DIR/uninstall"
		rm -rf "$DIR" "$LOCK"
		log "uninstalled"
		exit 0
	fi

	# udev starts us at boot and on every charger event in both modes. With
	# START=manual (until Start) or after Stop, all we do is make sure
	# charging is on, so the reader behaves as stock, and leave.
	state=$(cat "$STATE" 2>/dev/null)
	if [ "$state" = stopped ] || { [ "$START" = manual ] && [ "$state" != started ]; }; then
		stop "${announced:+stopped until started again}"
	fi

	# Diagnostics go to the USB drive once per boot, and again whenever the
	# user creates a "diagnose" file there.
	if [ -d /mnt/onboard/.kobo ] && { [ -z "$diag_saved" ] || [ -f "$USER_DIR/diagnose" ]; }; then
		mkdir -p "$USER_DIR"
		"$DIR/diagnostics.sh" > "$USER_DIR/diagnostics.txt" 2>&1
		rm -f "$USER_DIR/diagnose"
		diag_saved=1
	fi

	# Exits non-zero when this reader has no usable charge control; it still
	# prints what it found. Log that once, then idle.
	if ! status=$("$CHG" status 2>>"$LOG"); then
		if [ -z "$unavailable" ]; then
			eval "$status"
			log "no usable charge control (method=$method, pmic=$pmic), idling; see $USER_DIR/diagnostics.txt"
			unavailable=1
		fi
		nap
		continue
	fi
	eval "$status"
	if [ -z "$announced" ]; then
		log "started, version $(cat "$DIR/VERSION" 2>/dev/null), START=$START: method=$method pmic=$pmic battery=$battery"
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

	# Between RESUME and LIMIT keep the current state, so the stock driver
	# re-enabling charging there just tops the battery up to LIMIT.
	want=$charging_enabled
	if [ "$ENABLED" != 1 ] || [ "$plugged" = 0 ]; then
		want=1
	elif [ "$cap" -ge "$LIMIT" ]; then
		want=0
	elif [ "$cap" -le "$RESUME" ]; then
		want=1
	fi

	if [ "$want" != "$charging_enabled" ]; then
		if [ "$want" = 1 ]; then action=on; else action=off; fi
		"$CHG" "$action" 2>>"$LOG" && log "charging $action (battery ${cap}%, plugged=$plugged)"
	fi

	# The PMIC keeps charging while the reader sleeps and this loop can't run,
	# so while we're letting it charge towards LIMIT, a wake alarm brings the
	# reader back to check (the wake-up's power_supply event makes launch.sh
	# signal us). With charging off the battery can't climb, so no alarm is
	# needed. Only set when no alarm is pending, to leave Nickel's own alarms
	# alone.
	if [ "$WAKE_WHILE_CHARGING" = 1 ] && [ "$ENABLED" = 1 ] && [ "$plugged" = 1 ] &&
	   [ "$want" = 1 ] && [ -z "$(cat "$WAKEALARM" 2>/dev/null)" ]; then
		if (echo "+$WAKE_INTERVAL" > "$WAKEALARM") 2>/dev/null; then
			log "wake alarm set for +$WAKE_INTERVAL s (battery ${cap}%)"
		else
			log "could not set wake alarm"
		fi
	fi

	nap
done
