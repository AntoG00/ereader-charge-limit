#!/bin/sh
# Print a read-only report of what this reader offers for charge control, for
# users to attach to a bug report or a request to support their device. It
# never writes to the chip. The daemon saves it to the USB drive.

DIR=/usr/local/chargelimit

section() {
	echo
	echo "== $1 =="
}

echo "kobo-chargelimit diagnostics"
echo "version: $(cat "$DIR/VERSION" 2>/dev/null)"
echo "date: $(date '+%F %T %Z')"

section "verdict"
if "$DIR/kobo-chg" status 2>&1; then
	echo "supported: yes"
else
	echo "supported: no"
fi

# The first field of .kobo/version is the serial number; leave it out.
section "device"
echo "kobo version: $(cut -d, -f2- /mnt/onboard/.kobo/version 2>/dev/null)"
echo "kernel: $(uname -a)"
grep -E '^(Hardware|Revision)' /proc/cpuinfo

section "i2c devices"
for d in /sys/bus/i2c/devices/*; do
	[ -e "$d" ] || continue
	echo "${d##*/}: $(cat "$d/name" 2>/dev/null)"
done

# Every readable attribute, so an unknown driver's controls show up.
section "power supplies"
for s in /sys/class/power_supply/*; do
	[ -e "$s" ] || continue
	echo "[${s##*/}] -> $(readlink -f "$s/device")"
	for f in "$s"/*; do
		[ -f "$f" ] && [ -r "$f" ] || continue
		echo "  ${f##*/}: $(head -c 200 "$f" 2>/dev/null | tr '\n' ' ')"
	done
done

section "rtc"
for r in /sys/class/rtc/*; do
	[ -e "$r" ] || continue
	echo "${r##*/}: name=$(cat "$r/name" 2>/dev/null) wakealarm=$(cat "$r/wakealarm" 2>/dev/null)" \
		"wakeup=$(cat "$r/device/power/wakeup" 2>/dev/null) count=$(cat "$r/device/power/wakeup_count" 2>/dev/null)"
done

section "settings"
cat /mnt/onboard/.adds/chargelimit/config 2>/dev/null || echo "(no config file, defaults)"

section "log"
tail -n 50 /tmp/chargelimit.log 2>/dev/null

section "kernel log (power related)"
dmesg | grep -iE 'bd7|ricoh|pmic|charg|batt|power_supply' | tail -n 40
