#!/bin/sh
# Run at boot, on every power_supply change and after a setting changes:
# asks a running daemon to check now, or starts one.
DIR=$(cd "$(dirname "$0")" && pwd)
pid=$(cat /tmp/chargelimitd.lock/pid 2>/dev/null)
# USR1 kills processes that don't trap it, so make sure the pid is the daemon.
if [ -n "$pid" ] && grep -q chargelimitd "/proc/$pid/cmdline" 2>/dev/null; then
	kill -USR1 "$pid"
	exit 0
fi
setsid "$DIR/chargelimitd.sh" </dev/null >/dev/null 2>&1 &
