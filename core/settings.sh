# Sourced after platform.sh: the defaults, then the config on top.

CONFIG=$USER_DIR/config
# What the menu cycles LIMIT through.
LIMITS="70 80 90"

ENABLED=1
START=1
LIMIT=80
FULL_CHARGE=0
DIAGNOSE=0
UNINSTALL=0
POLL=30
WAKE_WHILE_CHARGING=$WAKE_WHILE_CHARGING_DEFAULT
WAKE_INTERVAL=120
[ -f "$CONFIG" ] && . "$CONFIG"

# The config is edited by hand: ENABLED and START are off only when exactly
# 0, so a typo never turns the limit off.
case $LIMIT in
'' | *[!0-9]*) LIMIT=80 ;;
esac
[ "$ENABLED" = 0 ] || ENABLED=1
[ "$START" = 0 ] || START=1
RESUME=$((LIMIT - 5))

# The next choice above LIMIT, wrapping around.
next_limit() {
	for l in $LIMITS; do
		[ "$l" -gt "$LIMIT" ] && { echo "$l"; return; }
	done
	echo "${LIMITS%% *}"
}

# A setting's menu label, "current setting - what a tap does". NickelMenu
# can't show ":".
label() {
	case $1 in
	toggle)
		if [ "$ENABLED" = 1 ]; then echo "Limit on - turn off"; else echo "Limit off - turn on"; fi ;;
	limit)
		echo "Limit ${LIMIT}% - set $(next_limit)%" ;;
	start)
		if [ "$START" = 1 ]; then echo "On at restart - set off"; else echo "Off at restart - set on"; fi ;;
	full)
		if [ "$FULL_CHARGE" = 1 ]; then echo "Full charge on - cancel"; else echo "Full charge once"; fi ;;
	esac
}

# Change one setting, keeping the config's comments.
set_setting() {
	storage_ready || return 1
	mkdir -p "${CONFIG%/*}" || return 1
	local source=$CONFIG updated=$CONFIG.tmp.$$
	[ -f "$source" ] || source=/dev/null
	# Write beside the config so the daemon reads either the old or new file.
	if ! awk -v key="$1" -v value="$2" '
		index($0, key "=") == 1 { $0 = key "=" value; found = 1 }
		{ print }
		END { if (!found) print key "=" value }
	' "$source" > "$updated" || ! mv -f "$updated" "$CONFIG"; then
		rm -f "$updated"
		return 1
	fi
	eval "$1=\$2"
	RESUME=$((LIMIT - 5))
}
