#!/bin/sh
# A read-only report of what this reader offers for charge control, for
# support requests. Never writes to the chip.

DIR=$(cd "$(dirname "$0")" && pwd)
. "$DIR/platform.sh"

section() {
	echo
	echo "== $1 =="
}

echo "Charge limit diagnostics"
echo "version: $(cat "$DIR/VERSION" 2>/dev/null)"
echo "date: $(date '+%F %T %Z')"

section "verdict"
if "$DIR/chargectl" status 2>&1; then
	echo "supported: yes"
else
	echo "supported: no"
fi

# The chip is the I2C device's name; the battery's driver can carry another
# chip's name (the BD71828's is bd71827-power).
section "power chip"
chip=
for d in /sys/bus/i2c/devices/*; do
	name=$(cat "$d/name" 2>/dev/null)
	case $name in
	bd71815 | bd71827 | bd71828 | ricoh619 | rc5t619) ;;
	*) continue ;;
	esac
	drv=$(readlink -f "$d/driver")
	drv=${drv##*/}
	echo "Power chip: $name (I2C ${d##*/}, driver ${drv:-none})"
	chip=1
done
[ -n "$chip" ] || echo "Power chip: none known (see i2c devices)"
for s in /sys/class/power_supply/*; do
	[ "$(cat "$s/type" 2>/dev/null)" = Battery ] || continue
	drv=$(readlink -f "$s/device/driver")
	drv=${drv##*/}
	if [ -e "$s/charging" ]; then sw=yes; else sw=no; fi
	echo "Battery: ${s##*/} (driver ${drv:-none}, charging switch: $sw)"
done

section "device"
device_info
echo "kernel: $(uname -a)"
grep -E '^(Hardware|Revision)' /proc/cpuinfo

section "i2c devices"
for d in /sys/bus/i2c/devices/*; do
	[ -e "$d" ] || continue
	echo "${d##*/}: $(cat "$d/name" 2>/dev/null)"
done
# Direct register access needs these.
echo "dev nodes: $(ls /dev/i2c-* 2>&1 | tr '\n' ' ')"

# A directory's attributes, [w] if writable (from the mode: root passes
# test -w). 4 KiB fits the BD7182x driver's register dump.
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

# Some drivers put their controls on the device; list each one once.
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
cat "$USER_DIR/config" 2>/dev/null || echo "(no config file, defaults)"

section "log"
tail -n 50 /tmp/chargelimit.log 2>/dev/null

section "kernel log (power related)"
dmesg | grep -iE 'bd7|ricoh|pmic|charg|batt|power_supply' | tail -n 40
