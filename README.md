# kobo-chargelimit (prototype)

Stops a Kobo Sage charging at 80% and runs it from the charger instead, like
AlDente on a Mac. It switches charging back on at 75%.

**Untested on hardware.** This is built from Kobo's published Sage kernel
source ([kobolabs/b300-sage](https://github.com/kobolabs/b300-sage)), not
from a real device. Do the manual test below before installing the package.

## How it works

The Sage's power chip is a Ricoh RC5T619. Register `0xB3` (CHGCTL1) bits 0–1
turn charging on and off. Kobo's own driver clears them when the battery is
too hot or cold and keeps the reader running from USB, which is the same mode
we want.

- `kobo-chg` is a small static binary: `status`, `on`, `off`. It talks to the
  chip over `/dev/i2c-N`, finding the bus by the driver's name in sysfs.
- `chargelimitd.sh` checks every 30 s. It turns charging off at `LIMIT`, on at
  `RESUME`, and leaves it alone in between.
- A udev rule starts the daemon at boot and on charger plug/unplug.

### The register-bank hazard

The chip has two register banks behind a select register (`0xFF`). The stock
driver remembers which bank it last selected and uses bank 1 at runtime for
fuel-gauge upkeep. A plain write to `0xB3` while bank 1 is selected would
corrupt a fuel-gauge setting, and changing the bank ourselves would confuse the
driver.

So `kobo-chg` never changes the bank. Each access reads the bank register in
the same atomic `I2C_RDWR` transfer as the register access. If bank 1 was
active, it puts the old byte back and retries. This needs the Allwinner I²C
driver to accept 4–5 messages per transfer. If it doesn't, `kobo-chg` exits
with an `I2C_RDWR` error and changes nothing.

## Manual test first

You need a root shell on the reader, for example SSH from NiLuJe's kobo-stuff
package (MobileRead forums).

1. Get `KoboRoot.tgz` (see Building) and pull the helper out of it, without
   installing the package:
   ```sh
   tar -xzf KoboRoot.tgz usr/local/chargelimit/kobo-chg
   ```
   Copy `usr/local/chargelimit/kobo-chg` to the reader's USB drive, so it's at
   `/mnt/onboard/kobo-chg` on the reader.
2. Check the chip is found and the status makes sense:
   ```sh
   ls /sys/bus/i2c/devices/                    # look for N-0032 or similar
   cat /sys/bus/i2c/devices/*/name             # one should say ricoh619
   /mnt/onboard/kobo-chg status
   ```
   Unplugged, expect `plugged=0`. Plugged in and charging, expect
   `plugged=1 charging_enabled=1`.
3. Plugged in, run `/mnt/onboard/kobo-chg off`, then:
   ```sh
   /mnt/onboard/kobo-chg status
   cat /sys/class/power_supply/battery/status         # expect Discharging
   cat /sys/class/power_supply/battery/current_now    # should drop to ~0
   ```
   The reader should stay on and the battery percentage should hold steady.
4. `/mnt/onboard/kobo-chg on`: charging should resume.
5. Leave it off for a while and check `dmesg | tail` and the battery
   percentage, to see whether the driver turns charging back on by itself.

If step 3 shows the battery draining while plugged in, the chip isn't feeding
the system from USB with charging off. Stop there: the approach doesn't work.

## Building

GitHub Actions builds the package on every push
([.github/workflows/build.yml](.github/workflows/build.yml)). Open the run on
the repo's **Actions** tab and download the `KoboRoot` artifact. GitHub zips
artifacts, so unzip it to get `KoboRoot.tgz`. You can also start a build by
hand from the Actions tab with **Run workflow**.

On Linux you can build locally instead:

```sh
sudo apt-get install gcc-arm-linux-gnueabihf libc6-dev-armhf-cross
sh build.sh    # writes build/KoboRoot.tgz
```

## Install

1. Get `KoboRoot.tgz` (see Building).
2. Copy it to the `.kobo/` folder on the reader's USB drive, then eject. The
   reader installs it and reboots.
3. Optional: copy `config.example` to `.adds/chargelimit/config` on the USB
   drive to change the limits.

The log is at `/tmp/chargelimit.log` (cleared on reboot). It records every
charging toggle, including each time the daemon had to undo the driver turning
charging back on.

## Turning it off or removing it

- Pause: set `ENABLED=0` in `.adds/chargelimit/config`.
- Uninstall: create an empty file `.adds/chargelimit/uninstall` on the USB
  drive. The daemon turns charging back on and deletes its own files and udev
  rule. (`KoboRoot.tgz` can add files but not remove them.)
- If something goes wrong, rebooting with the cable unplugged resets the chip;
  the stock driver turns charging on again at boot.

## Known gaps

- **Sleep.** The daemon can't run while the reader sleeps, but the chip keeps
  charging, and 80→100% takes about 20–30 minutes. Once charging is off it
  stays off during sleep, because the setting lives in the chip. Only a reader
  that falls asleep below 80% will overshoot.
  `WAKE_WHILE_CHARGING=1` sets an RTC wake alarm while charging below the
  limit. It's untested. Nickel may not go back to sleep after an RTC wake. The
  alarm can also block Nickel from setting its own (the kernel refuses a second
  alarm), which could delay its auto power-off while plugged in.
- **Driver re-enables.** The stock driver turns charging back on after some
  events: plug-in, temperature recovery, low-battery alerts. The daemon undoes
  this within `POLL` seconds.
- **Races with the driver.** `kobo-chg` detects the driver writing `0xB3` or
  switching banks mid-update and corrects for it, but it can't take the
  driver's lock. A kernel module could, if this turns out to matter.
- **Nickel's battery icon** may show "not charging" while plugged in.
- **The boot hook** uses udev's `loop0` event like kfmon does. If that doesn't
  fire on your firmware, the plug/unplug rule still starts the daemon the first
  time you connect a charger.
- **Firmware updates** may remove the udev rule. Reinstall `KoboRoot.tgz` if
  the log stops appearing.
