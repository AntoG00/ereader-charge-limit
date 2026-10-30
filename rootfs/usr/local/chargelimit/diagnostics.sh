#!/bin/sh
# Print a read-only report of what this reader offers for charge control, for
# users to attach to a bug report or a request to support their device. It
# never writes to the chip. The daemon saves it to the USB drive. On a reader
# with neither a "charging" file nor a known chip, it should show enough to
# find another switch: writable attributes, the driver's device folder, its
# register dump, /dev/i2c nodes and the kernel's drivers.

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
# Direct register access needs these.
echo "dev nodes: $(ls /dev/i2c-* 2>&1 | tr '\n' ' ')"

# Every attribute of a sysfs directory, marked [w] if writable, so an unknown
# driver's controls show up. Values are kept long enough for the BD7182x
# driver's "register" file, a dump of all the chip's registers. Root passes
# `test -w` on everything, so writability comes from the mode bits.
attrs() {
	for f in "$1"/*; do
		[ -f "$f" ] || continue
		case $(ls -l "$f") in
		??w*) w=" [w]" ;;
		*) w= ;;
		esac
		echo "  ${f##*/}$w: $(head -c 4096 "$f" 2>/dev/null | tr '\n' ' ')"
	done
}

section "power supplies"
for s in /sys/class/power_supply/*; do
	[ -e "$s" ] || continue
	echo "[${s##*/}] -> $(readlink -f "$s/device")"
	attrs "$s"
done

# Some drivers put their controls on the device instead of the supply. A
# chip's supplies share one device, so list each device once.
section "power supply devices"
seen=
for s in /sys/class/power_supply/*; do
	d=$(readlink -f "$s/device") && [ -d "$d" ] || continue
	case "$seen " in
	*" $d "*) continue ;;
	esac
	seen="$seen $d"
	echo "[$d]"
	attrs "$d"
done

# Names the charger, battery and PMIC drivers, which points to the right
# datasheet or kernel source for a chip we don't know.
section "drivers"
echo "modules: $(cut -d' ' -f1 /proc/modules 2>/dev/null | tr '\n' ' ')"
if [ -r /proc/config.gz ]; then
	zcat /proc/config.gz | grep -E '=(y|m)$' |
		grep -iE 'charg|batt|pmic|power|mfd_|regulator_|rtc_drv'
else
	echo "(no /proc/config.gz)"
fi

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
