#!/bin/sh
# The app's bridge: BusyBox tcpsvd on 127.0.0.1 runs this per request.
#
#   GET /<action>?token=<token>&_=<anything>
#
#   state      installed, current (install.sh --check), supported, version
#   install    install.sh
#   status toggle limit limit-off/70/80/90 start start-on/off
#   full activity diagnose progress labels uninstall
#              the installed actions.sh; diagnose and progress (of the
#              guided report on an unsupported Kindle) also before installing
#
# The token (token, app/bridge.js) keeps out pages in the Kindle's browser,
# which can reach 127.0.0.1 but not the app's files. "_" defeats caching.

UI=$(cd "$(dirname "$0")" && pwd)
PKG=${UI%/*}
. "$PKG/runtime/platform.sh"

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
	if sh "$PKG/install.sh" --check; then echo current=yes; else echo current=no; fi
	if "$PKG/runtime/chargectl" status >/dev/null 2>&1; then echo supported=yes; else echo supported=no; fi
	echo "version=$(cat "$PKG/runtime/VERSION")"
	;;
install)
	reply "200 OK"
	sh "$PKG/install.sh" 2>&1
	;;
status | toggle | limit | limit-off | limit-70 | limit-80 | limit-90 | \
start | start-on | start-off | full | activity | diagnose | progress | labels | uninstall)
	reply "200 OK"
	if [ -f "$INSTALL_DIR/actions.sh" ]; then
		"$INSTALL_DIR/actions.sh" "$action" 2>&1
	elif [ "$action" = diagnose ] || [ "$action" = progress ]; then
		sh "$PKG/runtime/actions.sh" "$action" 2>&1
	else
		echo "Charge Limit isn't installed."
	fi
	;;
*)
	reply "404 Not Found"
	echo "Unknown action: $action"
	;;
esac
