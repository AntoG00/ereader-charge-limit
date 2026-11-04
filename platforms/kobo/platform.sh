# Kobo: what differs from other readers, sourced by the core scripts
# (chargelimitd.sh, actions.sh, diagnostics.sh) before anything else.
#
# Installed by KoboRoot.tgz into /usr/local/chargelimit, on the system
# partition: it stays put while the USB partition is unmounted (USB mode),
# and udev rules must be in /etc anyway. The user's files live on the USB
# partition.

# The config, diagnostics report and anything else for the user to find.
USER_DIR=/mnt/onboard/.adds/chargelimit
# USER_DIR as users see it over USB, for messages.
USER_DIR_SHOWN=.adds/chargelimit
MENU=/mnt/onboard/.adds/nm/chargelimit
# The wake alarm while charging (settings.sh). The Sage wakes itself every
# ~87 s while plugged in, but other Kobos may sleep through a charge.
WAKE_WHILE_CHARGING_DEFAULT=1

# The USB partition is unmounted in USB mass-storage mode (.kobo is missing
# then), and at boot until it's mounted.
storage_ready() {
	[ -d /mnt/onboard/.kobo ]
}

# Which reader and firmware, for diagnostics. The first field of
# .kobo/version is the serial number; leave it out.
device_info() {
	echo "kobo version: $(cut -d, -f2- /mnt/onboard/.kobo/version 2>/dev/null)"
}

# NickelMenu re-reads its files whenever the menu opens, so the labels can
# show the current settings. Labels can't contain ":". Only written when it
# changed, to spare the flash and NickelMenu's reloads; skipped if
# NickelMenu isn't installed. Needs the settings (settings.sh) loaded.
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

# What uninstalling removes besides $DIR and $USER_DIR. KoboRoot.tgz can add
# files but not remove them, so the daemon does it.
platform_uninstall() {
	rm -f /etc/udev/rules.d/99-chargelimit.rules "$MENU"
}
