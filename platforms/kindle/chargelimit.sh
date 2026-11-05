#!/bin/sh
# Name: Charge Limit
# DontUseFBInk

UI=/mnt/us/extensions/chargelimit/ui
[ -f "$UI/open-app.sh" ] || exit 1
# Detached: the Kindle ends this scriptlet as soon as another app is in front.
setsid sh "$UI/open-app.sh" </dev/null >/dev/null 2>&1 &
# Wait for that: a scriptlet that ends first gets "The selected application
# could not be started" on some firmware (5.14.2), as the scriptlet runner
# then stops itself with nothing else in front.
sleep 15
