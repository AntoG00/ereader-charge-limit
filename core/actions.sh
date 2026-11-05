#!/bin/sh
# The menu's actions, in plain language: status, toggle, limit, start, full,
# activity, diagnose (the guided report, support.sh, on a reader we can't
# control), uninstall; progress (of that report), menu (rewrite the menu)
# and labels (for the Kindle app's buttons). Always exits 0: NickelMenu
# shows an error box instead of the output otherwise.

DIR=$(cd "$(dirname "$0")" && pwd)
ACTIVITY=/tmp/chargelimit-activity.log

. "$DIR/platform.sh"
. "$DIR/settings.sh"

# After a setting changed.
apply() {
	"$DIR/launch.sh"
	refresh_menu
}

# Battery power in watts from voltage (uV) and current (uA), as "0.48".
watts() {
	mw=$(((${voltage_uv:-0} / 1000) * (${current_ua:-0} / 1000) / 1000))
	[ "$mw" -lt 0 ] && mw=$((-mw))
	printf '%d.%02d' $((mw / 1000)) $((mw % 1000 / 10))
}

limit_line() {
	if [ "$ENABLED" = 0 ]; then
		echo "Charge limit is off: the battery charges to 100%."
	elif [ "$FULL_CHARGE" = 1 ]; then
		echo "Charging to 100% until you unplug, then the $LIMIT% limit is back."
	else
		echo "Charge limit is on: charging stops at $LIMIT% and resumes at $RESUME%."
	fi
}

status() {
	if ! s=$("$DIR/chargectl" status 2>/dev/null); then
		echo "This reader isn't supported yet."
		echo "Tap \"Charge diagnostics\" and send the file it saves."
		return
	fi
	eval "$s"
	limit_line
	if [ "$START" = 1 ]; then
		echo "It turns on when the reader restarts."
	else
		echo "It turns off when the reader restarts."
	fi
	echo
	# The driver's status, as the battery icon shows it: the current lags.
	bat_status=$(cat "$battery/status" 2>/dev/null)
	if [ "$plugged" = 0 ]; then
		echo "Battery $capacity%, not plugged in, using $(watts) W."
	elif [ "$charging_enabled" = 0 ]; then
		echo "Battery $capacity%, plugged in, holding: the charger powers the reader."
	elif [ "$bat_status" = Full ]; then
		echo "Battery $capacity%, plugged in, full."
	elif [ "$bat_status" = Charging ] && [ "${current_ua:-0}" -gt 0 ]; then
		echo "Battery $capacity%, plugged in, charging at $(watts) W."
	elif [ "$bat_status" = Charging ]; then
		# Just switched on: the current hasn't turned positive yet.
		echo "Battery $capacity%, plugged in, charging."
	else
		echo "Battery $capacity%, plugged in, not charging, using $(watts) W from the battery."
	fi
}

toggle() {
	set_setting ENABLED $((1 - ENABLED))
	# A pending full charge would otherwise come back with the limit.
	[ "$ENABLED" = 0 ] && [ "$FULL_CHARGE" = 1 ] && set_setting FULL_CHARGE 0
	limit_line
	apply
}

limit() {
	set_setting LIMIT "$(next_limit)"
	echo "Limit set to $LIMIT%: charging stops at $LIMIT% and resumes at $RESUME%."
	[ "$ENABLED" = 1 ] || echo "The charge limit is off; turn it on to use it."
	apply
}

start() {
	set_setting START $((1 - START))
	if [ "$START" = 1 ]; then
		echo "From the next restart, the charge limit turns on whenever the reader starts."
	else
		echo "From the next restart, the charge limit turns off whenever the reader starts."
	fi
	echo "Until then it stays as it is."
	refresh_menu
}

full() {
	if [ "$ENABLED" = 0 ]; then
		echo "The charge limit is off, so the battery already charges to 100%."
		return
	fi
	set_setting FULL_CHARGE $((1 - FULL_CHARGE))
	if [ "$FULL_CHARGE" = 1 ]; then
		echo "The battery charges to 100% until you next unplug the charger."
		echo "Then the $LIMIT% limit applies again."
	else
		echo "Full charge cancelled: charging stops at $LIMIT% again."
	fi
	apply
}

case "$1" in
status) status ;;
toggle) toggle ;;
limit) limit ;;
start) start ;;
full) full ;;
activity)
	if [ -s "$ACTIVITY" ]; then
		tail -n 10 "$ACTIVITY"
	else
		echo "Nothing yet since the reader started."
	fi
	;;
diagnose)
	# A reader we can't control gets the guided report instead.
	if ! "$DIR/chargectl" status >/dev/null 2>&1; then
		sh "$DIR/support.sh" tap
		exit 0
	fi
	mkdir -p "$USER_DIR"
	"$DIR/diagnostics.sh" > "$USER_DIR/diagnostics.log" 2>&1
	if grep -q '^supported: yes' "$USER_DIR/diagnostics.log"; then
		echo "This reader is supported."
	else
		echo "This reader isn't supported yet."
	fi
	grep -E '^(Power chip|Battery|Charger): ' "$USER_DIR/diagnostics.log"
	echo "Report saved as ${USER_DIR##*/}/diagnostics.log on the USB drive."
	echo "Connect the reader to a computer to copy it."
	;;
progress) sh "$DIR/support.sh" progress ;;
menu) refresh_menu ;;
labels)
	for key in toggle limit start full; do
		echo "$key=$(label "$key")"
	done
	;;
uninstall)
	set_setting UNINSTALL 1
	echo "Removing Charge Limit: charging goes back to normal, and its files and menu go away within a few seconds."
	"$DIR/launch.sh"
	;;
esac
exit 0
