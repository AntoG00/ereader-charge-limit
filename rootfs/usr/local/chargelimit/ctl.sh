#!/bin/sh
# The actions behind the NickelMenu items, in plain language:
#
#   ctl.sh status     settings, battery and what charging is doing
#   ctl.sh toggle     flip ENABLED: the limit on or off
#   ctl.sh limit      cycle LIMIT through 80, 85, 90, 95
#   ctl.sh start      flip START: what ENABLED becomes at each restart
#   ctl.sh full       flip FULL_CHARGE: charge to 100% until unplugged
#   ctl.sh activity   recent events, written by the daemon
#   ctl.sh diagnose   save the diagnostics report to the USB drive
#   ctl.sh menu       rewrite the NickelMenu file to show the current settings
#
# Every setting lives in the config, so the menu and hand edits behave the
# same; the daemon picks changes up at once because launch.sh signals it.
# The daemon's full log (/tmp/chargelimit.log) and the diagnostics report
# keep the technical detail. Every action exits 0, because NickelMenu shows
# an error box instead of the output otherwise.

DIR=/usr/local/chargelimit
USER_DIR=/mnt/onboard/.adds/chargelimit
ACTIVITY=/tmp/chargelimit.activity
MENU=/mnt/onboard/.adds/nm/chargelimit
LIMITS="80 85 90 95"

. "$DIR/settings.sh"

# The next choice after the current LIMIT, wrapping around; a hand-edited
# LIMIT that isn't one of the choices goes to the next one above it.
next_limit() {
	for l in $LIMITS; do
		[ "$l" -gt "$LIMIT" ] && { echo "$l"; return; }
	done
	echo "${LIMITS%% *}"
}

# NickelMenu re-reads its files whenever the menu opens, so the labels can
# show the current settings. Labels can't contain ":". Only written when it
# changed, to spare the flash and NickelMenu's reloads; skipped if
# NickelMenu isn't installed.
write_menu() {
	[ -d "${MENU%/*}" ] || return 0
	if [ "$ENABLED" = 1 ]; then
		onoff="Limit on - turn off"
	else
		onoff="Limit off - turn on"
	fi
	if [ "$START" = 1 ]; then
		start="On at restart - set off"
	else
		start="Off at restart - set on"
	fi
	if [ "$FULL_CHARGE" = 1 ]; then
		full="Full charge on - cancel"
	else
		full="Full charge once"
	fi
	cat > /tmp/chargelimit.menu <<EOF
# Written by kobo-chargelimit whenever its settings change; edits are lost.
menu_item :main :Charge status :cmd_output :5000:$DIR/ctl.sh status
menu_item :main :$onoff :cmd_output :5000:$DIR/ctl.sh toggle
menu_item :main :Limit ${LIMIT}% - set $(next_limit)% :cmd_output :5000:$DIR/ctl.sh limit
menu_item :main :$start :cmd_output :5000:$DIR/ctl.sh start
menu_item :main :$full :cmd_output :5000:$DIR/ctl.sh full
menu_item :main :Charge activity :cmd_output :5000:$DIR/ctl.sh activity
menu_item :main :Charge diagnostics :cmd_output :9000:$DIR/ctl.sh diagnose
EOF
	cmp -s /tmp/chargelimit.menu "$MENU" || cp /tmp/chargelimit.menu "$MENU"
	rm -f /tmp/chargelimit.menu
}

# After a setting changed: the daemon applies it now, and the labels follow.
apply() {
	"$DIR/launch.sh"
	write_menu
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
	if ! s=$("$DIR/kobo-chg" status 2>/dev/null); then
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
	if [ "$plugged" = 0 ]; then
		echo "Battery $capacity%, not plugged in, using $(watts) W."
	elif [ "$charging_enabled" = 0 ]; then
		echo "Battery $capacity%, plugged in, holding: the charger powers the reader."
	elif [ "${current_ua:-0}" -gt 0 ]; then
		echo "Battery $capacity%, plugged in, charging at $(watts) W."
	else
		echo "Battery $capacity%, plugged in, using $(watts) W from the battery."
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
	write_menu
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
	mkdir -p "$USER_DIR"
	"$DIR/diagnostics.sh" > "$USER_DIR/diagnostics.txt" 2>&1
	if grep -q '^supported: yes' "$USER_DIR/diagnostics.txt"; then
		echo "This reader is supported."
	else
		echo "This reader isn't supported yet."
	fi
	echo "Report saved as .adds/chargelimit/diagnostics.txt on the USB drive."
	echo "Connect the reader to a computer to copy it."
	;;
menu) write_menu ;;
esac
exit 0
