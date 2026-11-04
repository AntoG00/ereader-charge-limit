#!/bin/sh
# Open the Kindle app. The "Charge limit" scriptlet runs this detached
# (setsid), because the Kindle ends a scriptlet once it returns to the home
# screen. The app and its bridge run from here (install/ui) whether or not
# chargelimit is installed; the app's Install button installs it.

UI=$(cd "$(dirname "$0")" && pwd)
. "${UI%/*}/runtime/platform.sh"

# The bridge's token, made once (see bridge.sh), and where the app finds the
# bridge.
if [ ! -s "$UI/token" ]; then
	head -c 16 /dev/urandom | md5sum | cut -c1-32 > "$UI/token"
	cat > "$UI/app/bridge.js" <<EOF
var BRIDGE = "http://127.0.0.1:$BRIDGE_PORT/";
var TOKEN = "$(cat "$UI/token")";
EOF
fi

# Register the app with the Kindle's app manager (again each time: it's
# cheap, and the rows then always point here).
sqlite3 "$APPREG" <<EOF
INSERT OR IGNORE INTO interfaces (interface) VALUES ('application');
INSERT OR IGNORE INTO handlerIds (handlerId) VALUES ('$APP_ID');
INSERT OR IGNORE INTO associations (handlerId, interface, contentId, defaultAssoc)
    VALUES ('$APP_ID', 'application', 'GL:$APP_ID', 0);
INSERT OR REPLACE INTO properties (handlerId, name, value) VALUES ('$APP_ID', 'lipcId', '$APP_ID');
INSERT OR REPLACE INTO properties (handlerId, name, value)
    VALUES ('$APP_ID', 'command', '/usr/bin/mesquite -l $APP_ID -c file://$UI/app/');
INSERT OR REPLACE INTO properties (handlerId, name, value) VALUES ('$APP_ID', 'supportedOrientation', 'U');
EOF

# The bridge runs until the Kindle restarts, since the app can stay in the
# background for as long after the Kindle's × (which only hides it).
if [ -z "$(bridge_pid)" ]; then
	busybox tcpsvd -E 127.0.0.1 "$BRIDGE_PORT" sh "$UI/bridge.sh" </dev/null >/dev/null 2>&1 &
	echo $! > "$BRIDGE_PID"
fi

# A running app comes to the front with one start, and is told to refresh
# what it shows. A new one starts without Mesquite's cached copy (so a newer
# build copied into install/ shows), loads behind the home screen the Kindle
# shows once the scriptlet ends, and is started again after 2 s to bring it
# forward (only then: a second start redraws a running app twice).
if [ -n "$(pgrep -f "mesquite -l $APP_ID")" ]; then
	lipc-set-prop com.lab126.appmgrd start "app://$APP_ID"
	lipc-set-prop "$APP_ID" refresh -s now 2>/dev/null
else
	rm -rf "/var/local/mesquite/$APP_ID"
	lipc-set-prop com.lab126.appmgrd start "app://$APP_ID"
	sleep 2
	lipc-set-prop com.lab126.appmgrd start "app://$APP_ID"
fi
