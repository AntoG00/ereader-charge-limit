#!/bin/sh
# Open the app, starting its bridge if needed. Run by the scriptlet.

UI=$(cd "$(dirname "$0")" && pwd)
. "${UI%/*}/runtime/platform.sh"

# The bridge's token (see bridge.sh), made once.
if [ ! -s "$UI/token" ]; then
	head -c 16 /dev/urandom | md5sum | cut -c1-32 > "$UI/token"
	cat > "$UI/app/bridge.js" <<EOF
var BRIDGE = "http://127.0.0.1:$BRIDGE_PORT/";
var TOKEN = "$(cat "$UI/token")";
EOF
fi

# Register the app every time, so it always points here.
sqlite3 "$APPREG" <<EOF
.timeout 5000
INSERT OR IGNORE INTO interfaces (interface) VALUES ('application');
INSERT OR IGNORE INTO handlerIds (handlerId) VALUES ('$APP_ID');
INSERT OR IGNORE INTO associations (handlerId, interface, contentId, defaultAssoc)
    VALUES ('$APP_ID', 'application', 'GL:$APP_ID', 0);
INSERT OR REPLACE INTO properties (handlerId, name, value) VALUES ('$APP_ID', 'lipcId', '$APP_ID');
INSERT OR REPLACE INTO properties (handlerId, name, value)
    VALUES ('$APP_ID', 'command', '/usr/bin/mesquite -l $APP_ID -c file://$UI/app/');
INSERT OR REPLACE INTO properties (handlerId, name, value) VALUES ('$APP_ID', 'supportedOrientation', 'U');
EOF

# The bridge runs until a restart: the Kindle's × only hides the app.
if [ -z "$(bridge_pid)" ]; then
	busybox tcpsvd -E 127.0.0.1 "$BRIDGE_PORT" sh "$UI/bridge.sh" </dev/null >/dev/null 2>&1 &
	echo $! > "$BRIDGE_PID"
fi

# A running app gets one start and a refresh. A new one, without Mesquite's
# cache, loads behind the home screen the Kindle shows after the scriptlet,
# so it gets a second start after 2 s.
if [ -n "$(pgrep -f "mesquite -l $APP_ID")" ]; then
	lipc-set-prop com.lab126.appmgrd start "app://$APP_ID"
	lipc-set-prop "$APP_ID" refresh -s now 2>/dev/null
else
	rm -rf "/var/local/mesquite/$APP_ID"
	lipc-set-prop com.lab126.appmgrd start "app://$APP_ID"
	sleep 2
	lipc-set-prop com.lab126.appmgrd start "app://$APP_ID"
fi
