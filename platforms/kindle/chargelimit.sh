#!/bin/sh
# Name: Charge limit
# DontUseFBInk

UI=/mnt/us/extensions/chargelimit/ui
[ -f "$UI/open-app.sh" ] || exit 1
# Detached: the Kindle ends this scriptlet once it returns to the home screen.
setsid sh "$UI/open-app.sh" </dev/null >/dev/null 2>&1 &
