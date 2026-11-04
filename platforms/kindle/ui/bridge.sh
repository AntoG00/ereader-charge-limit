#!/bin/sh
# The Kindle app's way to run chargelimit: BusyBox tcpsvd, listening on
# 127.0.0.1 only (open-app.sh starts it), runs this once per request, with
# the connection as stdin and stdout. It runs from the installer's folder
# (install/ui), like the app, so it works before anything is installed. A
# request is
#
#   GET /<action>?token=<token>&_=<anything> HTTP/1.1
#
# and the answer is plain text:
#   state      installed=yes|no (actions can run), current=yes|no (this
#              build is installed with both boot files: install.sh --check),
#              supported=yes|no (chargectl can control charging here),
#              version=<the installer's build>
#   install    install.sh's output
#   status toggle limit start full activity diagnose labels uninstall
#              that action of the installed actions.sh; diagnose also works
#              before installing, from the installer's copy
# Nothing else can be run. The token, written by open-app.sh into token and
# app/bridge.js, keeps out web pages in the Kindle's browser, which could
# reach 127.0.0.1 too but can't read the app's files. "_" only defeats
# caching.

UI=$(cd "$(dirname "$0")" && pwd)
INSTALLER=${UI%/*}
. "$INSTALLER/runtime/platform.sh"

# "GET /status?token=… HTTP/1.1", then headers up to a blank line.
read -r method target proto
while IFS= read -r line; do
	case $line in
	'' | "$(printf '\r')") break ;;
	esac
done
action=${target%%\?*}
action=${action#/}
query=
case $target in
*\?*) query=${target#*\?} ;;
esac
# The token parameter's value: what follows "&token=" up to the next "&".
token=
rest=${query#*token=}
case "&$query" in
*"&token="*) token=${rest%%&*} ;;
esac

reply() {
	printf 'HTTP/1.0 %s\r\nContent-Type: text/plain; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' "$1"
}

if [ "$method" != GET ] || [ -z "$token" ] || [ "$token" != "$(cat "$UI/token" 2>/dev/null)" ]; then
	reply "403 Forbidden"
	echo "Not allowed."
	exit 0
fi

case $action in
state)
	reply "200 OK"
	if [ -f "$INSTALL_DIR/actions.sh" ]; then echo installed=yes; else echo installed=no; fi
	if sh "$INSTALLER/install.sh" --check; then echo current=yes; else echo current=no; fi
	if "$INSTALLER/runtime/chargectl" status >/dev/null 2>&1; then echo supported=yes; else echo supported=no; fi
	echo "version=$(cat "$INSTALLER/runtime/VERSION")"
	;;
install)
	reply "200 OK"
	sh "$INSTALLER/install.sh" 2>&1
	;;
status | toggle | limit | start | full | activity | diagnose | labels | uninstall)
	reply "200 OK"
	if [ -f "$INSTALL_DIR/actions.sh" ]; then
		"$INSTALL_DIR/actions.sh" "$action" 2>&1
	elif [ "$action" = diagnose ]; then
		sh "$INSTALLER/runtime/actions.sh" diagnose 2>&1
	else
		echo "chargelimit isn't installed."
	fi
	;;
*)
	reply "404 Not Found"
	echo "Unknown action: $action"
	;;
esac
