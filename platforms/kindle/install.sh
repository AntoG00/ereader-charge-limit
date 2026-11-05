#!/bin/sh
# Install the daemon and boot files from the package; run again to update or
# repair (firmware updates may remove the boot files). --check: is this
# build installed with both boot files?

P=$(cd "$(dirname "$0")" && pwd)
. "$P/runtime/platform.sh"
DIR=$INSTALL_DIR
LOCK=/tmp/chargelimitd.lock

if [ "$1" = --check ]; then
	cmp -s "$P/runtime/VERSION" "$DIR/VERSION" &&
		[ -f /etc/upstart/chargelimit.conf ] && [ -f /etc/udev/rules.d/99-chargelimit.rules ]
	exit
fi

# Stop a running daemon before replacing its scripts.
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

# Nothing goes on the system partition of a Kindle we can't control.
if ! "$DIR/chargectl" status >/dev/null 2>&1; then
	mkdir -p "$USER_DIR"
	"$DIR/diagnostics.sh" > "$USER_DIR/diagnostics.log" 2>&1
	rm -rf "$DIR"
	echo "This Kindle isn't supported yet, so nothing was installed."
	echo "A report was saved as ${USER_DIR##*/}/diagnostics.log on the USB drive."
	exit 1
fi

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

"$DIR/launch.sh"
. "$DIR/settings.sh"
echo "Charge Limit $(cat "$DIR/VERSION") is installed: charging stops at $LIMIT%."
echo "It starts by itself whenever the Kindle restarts."
