# Sourced by chargelimitd.sh and actions.sh, after platform.sh: the defaults,
# then the user's config on top. Re-sourcing it picks up config changes,
# including removed lines. The config is the only place settings live: the
# menu edits it too.

CONFIG=$USER_DIR/config
# The choices the menu cycles LIMIT through.
LIMITS="70 80 90"

ENABLED=1
START=1
LIMIT=80
FULL_CHARGE=0
DIAGNOSE=0
UNINSTALL=0
POLL=30
# Whether a reader needs the wake alarm depends on how it sleeps while
# charging, so each platform.sh sets the default.
WAKE_WHILE_CHARGING=$WAKE_WHILE_CHARGING_DEFAULT
WAKE_INTERVAL=120
[ -f "$CONFIG" ] && . "$CONFIG"

# The config is user-edited. A LIMIT that isn't a plain number would break
# the daemon's comparisons; ENABLED and START fall back to on unless they're
# exactly 0, so a typo never silently turns the limit off. The one-off
# actions only run on exactly 1.
case $LIMIT in
'' | *[!0-9]*) LIMIT=80 ;;
esac
[ "$ENABLED" = 0 ] || ENABLED=1
[ "$START" = 0 ] || START=1
RESUME=$((LIMIT - 5))

# The next choice after the current LIMIT, wrapping around; a hand-edited
# LIMIT that isn't one of the choices goes to the next one above it.
next_limit() {
	for l in $LIMITS; do
		[ "$l" -gt "$LIMIT" ] && { echo "$l"; return; }
	done
	echo "${LIMITS%% *}"
}

# The menu's label for a setting, as "current setting - what a tap does": the
# Kobo's NickelMenu items and the Kindle app's buttons. No ":" (NickelMenu
# can't show it).
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

# Change one setting in the config in place, keeping the user's comments, and
# in this shell. Fails while the user's storage is unavailable, where writing
# would land under the bare mount point.
set_setting() {
	storage_ready || return 1
	mkdir -p "${CONFIG%/*}"
	if grep -q "^$1=" "$CONFIG" 2>/dev/null; then
		sed "s/^$1=.*/$1=$2/" "$CONFIG" > "/tmp/chargelimit.config.$$" &&
			cat "/tmp/chargelimit.config.$$" > "$CONFIG"
		rm -f "/tmp/chargelimit.config.$$"
	else
		echo "$1=$2" >> "$CONFIG"
	fi
	eval "$1=\$2"
	RESUME=$((LIMIT - 5))
}
