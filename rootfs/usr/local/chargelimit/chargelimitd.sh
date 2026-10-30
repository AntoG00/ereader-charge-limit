#!/bin/sh
# Keep the Kobo Sage's battery between RESUME and LIMIT percent while plugged
# in. At LIMIT the PMIC's charger is switched off and the reader runs from USB.

DIR=/usr/local/chargelimit
CHG=$DIR/kobo-chg
USER_DIR=/mnt/onboard/.adds/chargelimit
CAPACITY=/sys/class/power_supply/battery/capacity
VOLTAGE=/sys/class/power_supply/battery/voltage_now
WAKEALARM=/sys/class/rtc/rtc0/wakealarm
LOG=/tmp/chargelimit.log
LOCK=/tmp/chargelimitd.lock

# Defaults; $USER_DIR/config may override any of these.
ENABLED=1
LIMIT=80
RESUME=75
POLL=30
WAKE_WHILE_CHARGING=0
WAKE_INTERVAL=600

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
# a reboot; until then the pid check below catches it.
if ! mkdir "$LOCK" 2>/dev/null; then
	kill -0 "$(cat "$LOCK/pid" 2>/dev/null)" 2>/dev/null && exit 0
fi
echo $$ > "$LOCK/pid"

# Hand charging back to the stock driver whenever we stop.
stop() {
	"$CHG" on
	rm -rf "$LOCK"
	log "$1"
	exit 0
}
trap 'stop stopped' TERM INT

log "started"
while :; do
	# The user partition is unmounted while the reader is in USB mass-storage
	# mode; the last settings read stay in effect until it's back.
	[ -f "$USER_DIR/config" ] && . "$USER_DIR/config"
	if [ -f "$USER_DIR/uninstall" ]; then
		"$CHG" on
		rm -f /etc/udev/rules.d/99-chargelimit.rules "$USER_DIR/uninstall"
		rm -rf "$DIR" "$LOCK"
		log "uninstalled"
		exit 0
	fi

	if ! status=$("$CHG" status 2>>"$LOG"); then
		log "could not read PMIC status"
		nap
		continue
	fi
	eval "$status"
	read -r cap < "$CAPACITY"

	# Awake, checks are at most POLL seconds apart, so a longer gap means the
	# reader slept. Log what this first check after waking sees, to show
	# whether the battery reading is fresh (voltage moves even if % doesn't).
	now=$(date +%s)
	if [ -n "$last" ] && [ $((now - last)) -gt $((POLL + 10)) ]; then
		read -r volt < "$VOLTAGE"
		log "check after $((now - last)) s asleep: battery ${cap}% ${volt}uV, charging_enabled=$charging_enabled, plugged=$plugged"
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

	# Experimental. The PMIC keeps charging while the reader sleeps and this
	# loop can't run, so a wake alarm brings it back to check. Only set when no
	# alarm is pending, to leave Nickel's own alarms alone.
	if [ "$WAKE_WHILE_CHARGING" = 1 ] && [ "$ENABLED" = 1 ] && [ "$plugged" = 1 ] &&
	   [ "$cap" -lt "$LIMIT" ] && [ -z "$(cat "$WAKEALARM" 2>/dev/null)" ]; then
		if (echo "+$WAKE_INTERVAL" > "$WAKEALARM") 2>/dev/null; then
			log "wake alarm set for +$WAKE_INTERVAL s (battery ${cap}%)"
		else
			log "could not set wake alarm"
		fi
	fi

	nap
done
