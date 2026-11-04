#!/bin/sh
# Name: Charge install
# DontUseFBInk
#
# Installs chargelimit from chargelimit/install/, or repairs it: run it again
# after a firmware update. Uninstalling removes this scriptlet too.

P=/mnt/us/chargelimit/install
[ -f "$P/install.sh" ] || exit 1
. "$P/runtime/show.sh"
sh "$P/install.sh" 2>&1 | show 10
