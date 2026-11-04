# Kindle: what differs from other readers, sourced by the core scripts
# (chargelimitd.sh, actions.sh, diagnostics.sh), install.sh and the UI's
# scripts before anything else. Experimental, tested on the Paperwhite 11th
# gen.
#
# Installing puts the daemon's code in /var/local/chargelimit, a persistent
# ext3 partition that stays mounted over USB, and two boot files on the
# read-only root filesystem (the upstart job and the udev rule), written
# between `mntroot rw` and `mntroot ro`. The user's files live in user
# storage, next to the installer's.
#
# The UI is an HTML app run by the Kindle's Mesquite, registered in
# /var/local/appreg.db. It and its bridge (BusyBox tcpsvd on 127.0.0.1,
# running bridge.sh per request) always run from the installer's folder,
# USER_DIR/install/ui, so they work before anything is installed: the app's
# Install button runs install.sh.

# The config, diagnostics report, and the installer with the UI (install/).
USER_DIR=/mnt/us/chargelimit
# Where install.sh puts the daemon's code.
INSTALL_DIR=/var/local/chargelimit
# USER_DIR as users see it over USB, for messages.
USER_DIR_SHOWN=chargelimit
# The library, where the "Charge limit" scriptlet (chargelimit.sh) lives.
DOCUMENTS=/mnt/us/documents
# Plugged in and charging, the Kindle stays awake behind the screensaver, so
# the daemon keeps checking; held at the limit it suspends, but then the
# battery can't climb. The wake alarm is never needed.
WAKE_WHILE_CHARGING_DEFAULT=0

# The app's id, also in ui/app/config.xml. Mesquite runs each app as
# "mesquite -l <id> ...", and the app gets lipc events sent to <id>.
APP_ID=com.chargelimit.app
APPREG=/var/local/appreg.db
BRIDGE_PORT=47815
BRIDGE_PID=/tmp/chargelimit-bridge.pid

# User storage is mounted from early in boot and stays mounted over USB
# (MTP); documents/ is missing only before it's mounted.
storage_ready() {
	[ -d "$DOCUMENTS" ]
}

device_info() {
	echo "kindle firmware: $(cat /etc/prettyversion.txt 2>/dev/null)"
}

# The app asks for the labels each time it shows them.
refresh_menu() {
	:
}

# The daemon calls this when the plug, charging or battery level changed:
# the app, if it's running, refreshes its status. Fails quietly otherwise.
notify_ui() {
	lipc-set-prop "$APP_ID" statusChanged -s now 2>/dev/null
}

# The running bridge's pid, if any.
bridge_pid() {
	pid=$(cat "$BRIDGE_PID" 2>/dev/null)
	[ -n "$pid" ] && grep -q tcpsvd "/proc/$pid/cmdline" 2>/dev/null && echo "$pid"
}

# What uninstalling removes besides $DIR and $USER_DIR (which holds the
# installer and the UI): the app (closed first: the Kindle's × only hides it)
# and its registration, the bridge, Mesquite's cached copy, the scriptlet,
# and the boot files. Only the daemon runs it, so LOG and log() are its.
platform_uninstall() {
	lipc-set-prop com.lab126.appmgrd stop "app://$APP_ID" 2>/dev/null
	pid=$(bridge_pid) && kill "$pid"
	rm -rf "/var/local/mesquite/$APP_ID" "$BRIDGE_PID"
	# The app manager may still be writing appreg.db as it closes the app,
	# so wait for it rather than fail at once (sqlite3's default).
	sqlite3 "$APPREG" >>"$LOG" 2>&1 <<EOF
.timeout 5000
DELETE FROM properties WHERE handlerId='$APP_ID';
DELETE FROM associations WHERE handlerId='$APP_ID';
DELETE FROM handlerIds WHERE handlerId='$APP_ID';
EOF
	left=$(sqlite3 "$APPREG" "SELECT count(*) FROM properties WHERE handlerId='$APP_ID';" 2>&1)
	[ "$left" = 0 ] || log "couldn't remove the app's registration ($left rows left)"
	rm -f "$DOCUMENTS/chargelimit.sh"
	/usr/sbin/mntroot rw >/dev/null 2>&1
	rm -f /etc/upstart/chargelimit.conf /etc/udev/rules.d/99-chargelimit.rules
	/usr/sbin/mntroot ro >/dev/null 2>&1
}
