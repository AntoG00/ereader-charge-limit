#!/bin/sh
# Name: Charge limit
# DontUseFBInk
#
# chargelimit's only item in the library: opens its app, which installs
# chargelimit with its Install button and runs from chargelimit/install/ui.
# Uninstalling removes this scriptlet too.

UI=/mnt/us/chargelimit/install/ui
[ -f "$UI/open-app.sh" ] || exit 1
# Detached: the Kindle ends this scriptlet once it returns to the home screen.
setsid sh "$UI/open-app.sh" </dev/null >/dev/null 2>&1 &
