#!/bin/sh
# Run by udev. Detach the daemon so udev doesn't kill it when the event
# finishes; the daemon itself makes sure only one copy runs.
setsid /usr/local/chargelimit/chargelimitd.sh </dev/null >/dev/null 2>&1 &
