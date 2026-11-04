# Kindle: what differs from other readers, sourced by the core scripts
# (chargelimitd.sh, actions.sh, diagnostics.sh) and install.sh before
# anything else. Experimental, tested on the Paperwhite 11th gen.
#
# install.sh copies the code to /var/local/chargelimit, a persistent ext3
# partition that stays mounted over USB. The root filesystem is read-only, so
# the two boot files there (the upstart job and the udev rule) are written
# between `mntroot rw` and `mntroot ro`. The user's files live in user
# storage, next to the installer's own files.

# The config, diagnostics report, and the installer (install/) to run again.
USER_DIR=/mnt/us/chargelimit
# USER_DIR as users see it over USB, for messages.
USER_DIR_SHOWN=chargelimit
# The library: each action is a scriptlet here (chargelimit-*.sh).
DOCUMENTS=/mnt/us/documents
# Plugged in and charging, the Kindle stays awake behind the screensaver, so
# the daemon keeps checking; held at the limit it suspends, but then the
# battery can't climb. The wake alarm is never needed.
WAKE_WHILE_CHARGING_DEFAULT=0

# User storage is mounted from early in boot and stays mounted over USB
# (MTP); documents/ is missing only before it's mounted.
storage_ready() {
	[ -d "$DOCUMENTS" ]
}

device_info() {
	echo "kindle firmware: $(cat /etc/prettyversion.txt 2>/dev/null)"
}

# The scriptlets have fixed names, so there's nothing to rewrite.
refresh_menu() {
	:
}

# What uninstalling removes besides $DIR and $USER_DIR (which holds the
# installer): the boot files and the scriptlets, the installer's included.
platform_uninstall() {
	/usr/sbin/mntroot rw >/dev/null 2>&1
	rm -f /etc/upstart/chargelimit.conf /etc/udev/rules.d/99-chargelimit.rules
	/usr/sbin/mntroot ro >/dev/null 2>&1
	rm -f "$DOCUMENTS"/chargelimit-*.sh
}
