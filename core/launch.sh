#!/bin/sh
# Run at boot, on every power_supply change and after a setting changes:
# asks a running daemon to check now, or starts one.
DIR=$(cd "$(dirname "$0")" && pwd)
LOCK=/tmp/chargelimitd.lock
pid=$(cat "$LOCK/pid" 2>/dev/null)
# USR1 kills processes that don't trap it, so make sure the pid is the daemon.
if [ -n "$pid" ] && grep -q chargelimitd "/proc/$pid/cmdline" 2>/dev/null; then
	if cmp -s "$LOCK/version" "$DIR/VERSION"; then
		kill -USR1 "$pid"
		exit 0
	fi
	# A Kobo update unpacks over a running daemon, which keeps its old code.
	kill "$pid"
	n=0
	while [ -d "$LOCK" ] && [ "$n" -lt 10 ]; do
		sleep 1
		n=$((n + 1))
	done
fi
setsid "$DIR/chargelimitd.sh" </dev/null >/dev/null 2>&1 &
