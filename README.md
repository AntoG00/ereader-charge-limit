# kobo-chargelimit (prototype)

Stops a Kobo Sage charging at 80% and runs it from the charger instead, like
AlDente on a Mac. It switches charging back on at 75%.

## Status

| | ROHM BD71828 | Ricoh RC5T619 |
|---|---|---|
| `kobo-chg` on/off/status (direct register) | Works (retail Sage, firmware 4.x) | Untested |
| Driver's `battery/charging` file | Present, tracks CHG_EN, writing `1`/`0` turns charging on/off | Not in the published driver; used if a newer one adds it |
| Runs from the charger with charging off | Yes, battery current ~0 mA, level held for 15 min | Untested |
| Daemon | Works: switched charging off again within 30 s after a manual re-enable | Untested |
| Boot hook | Daemon was running after the install reboot; whether `loop0` or a plug event started it isn't checked | Untested |

On a new reader or chip, do the manual test below before installing the
package.

## How it works

Sages ship with one of two power chips, and `kobo-chg` detects which one at
runtime:

- **ROHM BD71828**, found on a retail Sage (`2-004b`, driver
  `bd71827-power`). Register `0x6F` (CHG_EN) bit 0 turns charging on and off.
  Mainline Linux's driver for this chip uses the same bit for its
  "inhibit-charge" mode, where the device runs from the charger. Kobo hasn't
  published the kernel for this version, so the register map comes from
  mainline Linux (`rohm-bd71828.h`). Kobo's driver also exposes this bit as
  `/sys/class/power_supply/battery/charging`. The
  [Clara BW KOReader plugin](https://github.com/jopidovba-a11y/Charge-Limit-For-Kobo-Clara-BW-Koreader-Plugin)
  uses the same file (under `bd71827_bat/` on that model), and users report it
  on other Kobos with the same chip family.
- **Ricoh RC5T619**, the only chip in Kobo's published Sage kernel source
  ([kobolabs/b300-sage](https://github.com/kobolabs/b300-sage)). Register
  `0xB3` (CHGCTL1) bits 0–1 turn charging on and off. Kobo's own driver clears
  them when the battery is too hot or cold and keeps the reader running from
  USB, which is the same mode we want.

- `kobo-chg` is a small static binary: `status`, `on`, `off`. It talks to the
  chip over `/dev/i2c-N`, finding the bus and the chip by the driver's name in
  sysfs. On either chip, `on`/`off` write the driver's
  `/sys/class/power_supply/battery/charging` file when it exists, so the
  driver makes the change under its own lock, then read the register back.
  They write the register directly when the file is missing or the bit didn't
  follow.
- `chargelimitd.sh` checks every 30 s. It turns charging off at `LIMIT`, on at
  `RESUME`, and leaves it alone in between.
- A udev rule starts the daemon at boot and on charger plug/unplug.

### The register-bank hazard (Ricoh only)

The BD71828 has a single register page, so this only applies to the Ricoh.
The Ricoh has two register banks behind a select register (`0xFF`). The stock
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
package (MobileRead forums). Without one, on firmware 4.x, install
[NickelMenu](https://pgaskin.net/NickelMenu/) and copy
[nickelmenu/chargelimit-test](nickelmenu/chargelimit-test) to `.adds/nm/`. It
adds menu items that run the same commands and show the output on screen.

1. Get `KoboRoot.tgz` (see Building) and pull the helper out of it, without
   installing the package:
   ```sh
   tar -xzf KoboRoot.tgz usr/local/chargelimit/kobo-chg
   ```
   Copy `usr/local/chargelimit/kobo-chg` to the reader's USB drive, so it's at
   `/mnt/onboard/kobo-chg` on the reader.
2. Check the chip is found and the status makes sense:
   ```sh
   cat /sys/bus/i2c/devices/*/name             # one should say bd71828 or ricoh619
   /mnt/onboard/kobo-chg status
   ```
   Expect `pmic=bd71828` or `pmic=ricoh619`. Unplugged, expect `plugged=0`.
   Plugged in and charging, expect `plugged=1 charging_enabled=1`.
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
- On the Ricoh, a reboot always turns charging back on, because the stock
  driver switches it on while starting up (`ricoh61x_init_charger`). On the
  BD71828 this isn't known: mainline Linux's driver never sets CHG_EN at
  startup, and Kobo's driver isn't public. Use `kobo-chg on` to be sure.
  With the package installed, the daemon also turns charging on whenever the
  charger is unplugged or `ENABLED=0`. To get stock behaviour back for good,
  use `ENABLED=0` or the uninstall file.

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
- **Races with the driver.** The driver's `charging` file avoids them. For
  direct register writes (when the file is missing or didn't take effect), `kobo-chg` detects the driver writing the charge-enable register
  (or, on the Ricoh, switching banks) mid-update and corrects for it, but it
  can't take the driver's lock. A kernel module could, if this turns out to
  matter.
- **Nickel's battery icon** shows no charging symbol while charging is off,
  even though the charger is powering the reader.
- **The boot hook** uses udev's `loop0` event like kfmon does. If that doesn't
  fire on your firmware, the plug/unplug rule still starts the daemon the first
  time you connect a charger.
- **Firmware updates** may remove the udev rule. Reinstall `KoboRoot.tgz` if
  the log stops appearing.
