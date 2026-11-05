# Kobo: what differs from other readers, sourced first by the core scripts.
# Installed in /usr/local/chargelimit, which stays mounted in USB mode.

# The config and diagnostics.log (not .txt, which Nickel lists as a book).
USER_DIR=/mnt/onboard/chargelimit
MENU=/mnt/onboard/.adds/nm/chargelimit
# Some Kobos may sleep through a charge without the wake alarm.
WAKE_WHILE_CHARGING_DEFAULT=1

# Unmounted in USB mode, and early at boot.
storage_ready() {
	[ -d /mnt/onboard/.kobo ]
}

# The first field of .kobo/version is the serial number; leave it out.
device_info() {
	echo "kobo version: $(cut -d, -f2- /mnt/onboard/.kobo/version 2>/dev/null)"
}

# NickelMenu re-reads it on every open, so the labels show the current
# settings. Written only when it changed; skipped without NickelMenu.
refresh_menu() {
	[ -d "${MENU%/*}" ] || return 0
	cat > /tmp/chargelimit.menu <<EOF
# Written by chargelimit whenever its settings change; edits are lost.
menu_item :main :Charge status :cmd_output :5000:$DIR/actions.sh status
menu_item :main :$(label toggle) :cmd_output :5000:$DIR/actions.sh toggle
menu_item :main :$(label limit) :cmd_output :5000:$DIR/actions.sh limit
menu_item :main :$(label start) :cmd_output :5000:$DIR/actions.sh start
menu_item :main :$(label full) :cmd_output :5000:$DIR/actions.sh full
menu_item :main :Charge activity :cmd_output :5000:$DIR/actions.sh activity
menu_item :main :Charge diagnostics :cmd_output :9000:$DIR/actions.sh diagnose
EOF
	cmp -s /tmp/chargelimit.menu "$MENU" || cp /tmp/chargelimit.menu "$MENU"
	rm -f /tmp/chargelimit.menu
}

# NickelMenu items read the status when tapped.
notify_ui() {
	:
}

# What uninstalling removes besides $DIR and $USER_DIR.
platform_uninstall() {
	rm -f /etc/udev/rules.d/99-chargelimit.rules "$MENU"
}
