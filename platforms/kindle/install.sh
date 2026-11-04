#!/bin/sh
# Install chargelimit on a Kindle. The "Charge install" scriptlet runs this
# from the installer's folder (USER_DIR/install), which stays on the Kindle:
# running it again repairs an install, for example after a firmware update
# removed the boot files. It prints what happened, for the scriptlet to show.
#
#   install/
#     install.sh, chargelimit.conf, 99-chargelimit.rules
#     scriptlets/   chargelimit-*.sh, the actions, for the library
#     runtime/      the core, platform.sh, show.sh, chargectl, VERSION

P=$(cd "$(dirname "$0")" && pwd)
DIR=/var/local/chargelimit
LOCK=/tmp/chargelimitd.lock

# A running daemon is replaced: stopping it switches charging on and removes
# the lock. Replacing a shell script while it runs would break it.
pid=$(cat "$LOCK/pid" 2>/dev/null)
if [ -n "$pid" ] && grep -q chargelimitd "/proc/$pid/cmdline" 2>/dev/null; then
	kill "$pid"
	n=0
	while [ -d "$LOCK" ] && [ "$n" -lt 10 ]; do
		sleep 1
		n=$((n + 1))
	done
fi

rm -rf "$DIR"
if ! mkdir -p "$DIR" || ! cp -R "$P/runtime/." "$DIR/"; then
	rm -rf "$DIR"
	echo "Install failed: couldn't copy the files to $DIR."
	exit 1
fi
chmod 755 "$DIR"/*.sh "$DIR/chargectl"
. "$DIR/platform.sh"
. "$DIR/settings.sh"

# Nothing goes on the system partition of a Kindle we can't control.
if ! "$DIR/chargectl" status >/dev/null 2>&1; then
	mkdir -p "$USER_DIR"
	"$DIR/diagnostics.sh" > "$USER_DIR/diagnostics.txt" 2>&1
	rm -rf "$DIR"
	echo "This Kindle isn't supported yet, so nothing was installed."
	echo "A report was saved as $USER_DIR_SHOWN/diagnostics.txt on the USB drive."
	exit 1
fi

# The upstart job starts the daemon at boot; the udev rule signals it on
# every power event. udev reads the new rule at once.
/usr/sbin/mntroot rw >/dev/null 2>&1
cp "$P/chargelimit.conf" /etc/upstart/ &&
	cp "$P/99-chargelimit.rules" /etc/udev/rules.d/ &&
	chmod 644 /etc/upstart/chargelimit.conf /etc/udev/rules.d/99-chargelimit.rules
copied=$?
/usr/sbin/mntroot ro >/dev/null 2>&1
if [ "$copied" != 0 ]; then
	rm -rf "$DIR"
	echo "Install failed: couldn't write the boot files to the system partition."
	exit 1
fi
udevadm control --reload-rules 2>/dev/null

cp "$P"/scriptlets/chargelimit-*.sh "$DOCUMENTS/"

"$DIR/launch.sh"

echo "chargelimit $(cat "$DIR/VERSION") is installed, with the charge limit at $LIMIT%."
echo
echo "It starts by itself whenever the Kindle restarts."
echo "The Charge items in your library show what it's doing and change its settings. $USER_DIR_SHOWN/config has all of them."
