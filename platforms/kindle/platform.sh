# Kindle: what differs from other readers, sourced first by the core
# scripts, install.sh and the UI scripts. Installing puts the daemon in
# /var/local/chargelimit and two boot files on the read-only root. The app
# and its bridge run from the package, so they work before installing.

PACKAGE_DIR=/mnt/us/extensions/chargelimit
INSTALL_DIR=/var/local/chargelimit
# The config and diagnostics.log.
USER_DIR=/mnt/us/chargelimit
DOCUMENTS=/mnt/us/documents
# A Kindle stays awake while charging, so it needs no wake alarm.
WAKE_WHILE_CHARGING_DEFAULT=0

# Also in ui/app/config.xml; the app gets lipc events sent to it.
APP_ID=com.chargelimit.app
APPREG=/var/local/appreg.db
BRIDGE_PORT=47815
BRIDGE_PID=/tmp/chargelimit-bridge.pid

# Stays mounted over USB (MTP); missing only early at boot.
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

# A running app refreshes its status.
notify_ui() {
	lipc-set-prop "$APP_ID" statusChanged -s now 2>/dev/null
}

bridge_pid() {
	pid=$(cat "$BRIDGE_PID" 2>/dev/null)
	[ -n "$pid" ] && grep -q tcpsvd "/proc/$pid/cmdline" 2>/dev/null && echo "$pid"
}

# What uninstalling removes besides $DIR and $USER_DIR. The app is stopped
# first: the Kindle's × only hides it. Run by the daemon (LOG, log).
platform_uninstall() {
	lipc-set-prop com.lab126.appmgrd stop "app://$APP_ID" 2>/dev/null
	pid=$(bridge_pid) && kill "$pid"
	rm -rf "$PACKAGE_DIR" "/var/local/mesquite/$APP_ID" "$BRIDGE_PID"
	# The app manager may still be writing appreg.db.
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
