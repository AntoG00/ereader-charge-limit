#!/bin/sh
# Run at boot (by udev on a Kobo, upstart on a Kindle) and by udev on every
# power_supply change (plug, unplug, battery updates, including those right
# after a wake-up), and after a menu action changes a setting. A running
# daemon gets USR1 so it checks now instead of at the end of its POLL sleep.
# Otherwise start it, detached so its caller doesn't kill it on finishing;
# the daemon itself makes sure only one copy runs.
DIR=$(cd "$(dirname "$0")" && pwd)
pid=$(cat /tmp/chargelimitd.lock/pid 2>/dev/null)
# USR1 kills processes that don't trap it, so make sure the pid is the daemon.
if [ -n "$pid" ] && grep -q chargelimitd "/proc/$pid/cmdline" 2>/dev/null; then
	kill -USR1 "$pid"
	exit 0
fi
setsid "$DIR/chargelimitd.sh" </dev/null >/dev/null 2>&1 &
