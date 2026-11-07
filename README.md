# Charge Limit

Lets you limit your e-reader's maximum charging percentage to preserve its battery health.

It doesn't need KOReader or any other dependency, so you can keep using the native reading experience.

## Why I built this and why you might want to use it

Lithium-ion batteries wear faster when they are charged to 100%, and while phones and laptops might already offer a charge limit, e-readers don't seem to do that.

A lot of the time I use my e-reader on a stand, plugged in, at my desk or as a bedside reader. However, by doing this it keeps the battery level at 100% and it keeps using energy from the battery instead of the charger, so the battery is being used while being charged.

Because of this, I created this tool that sets a charge limit (80%) while allowing the e-reader to use power directly from the charger bypassing the battery, so there is no additional wear when not necessary. This way I hope to not need to replace its battery any time soon, as a quick search showed it to be basically impossible. It works with the reader's own software and keeps working in the background, while the reader sleeps and after a restart.

<p align="center">
  <img src="assets/kindle.png" alt="The Charge Limit app on a Kindle" width="300">
  <img src="assets/kobo.png" alt="Charge status on a Kobo" width="300">
</p>

---

## Features

- Stops charging at the limit (70, 80 or 90%) and resumes 5% lower, while the reader keeps running from the charger
- Charges to 100% once when you need it, then goes back to the limit after you unplug
- Works while the reader sleeps, and starts by itself when the reader restarts
- Can be turned off for a while, or set to stay off after restarts
- Settings and charging status on the e-reader
- Can be uninstalled completely by itself, and switches charging back on

---

## Supported e-readers

Charge Limit switches charging off and on through the power chip's driver, so support depends on the chip and its driver.

This tool has been tested on Kobo and Kindle devices:
- NickelMenu **is not required** on the Kobo in order for this tool to work. However, without NickelMenu you won't be able to see the charging status menu, and settings need to be changed in the config file.
- Kindle devices need to be **jailbroken**

### Tested Devices

| E-reader | Power chip | Driver | Status |
|---|---|---|---|
| Kobo Sage | ROHM BD71828 | `bd71827-power` | Tested (firmware 4.38) |
| Kindle Paperwhite 11th gen | ROHM BD71828 | `bd71827-power` | Tested (firmware 5.19.2, jailbroken) |
| Kindle Paperwhite 7th gen | Maxim MAX77696 | `max77696-charger` | Tested (firmware 5.14.2, jailbroken) |
| Kindle Scribe | TI BQ25611D | `bq256xx-charger` | Tested (firmware 5.19.5, jailbroken) |

The driver is named after the BD71828's sibling, the BD71827, and so are its battery files (`bd71827_bat`). **Charge diagnostics** shows both the power chip and its driver.

On a reader it can't control, Charge Limit does nothing to the charging, except during the short test **Charge diagnostics** runs there to help add support; see [Help add support for your e-reader](#help-add-support-for-your-e-reader).

---

## Installation

Download the ZIP for your reader from the [latest release](https://github.com/chengandre/ereader-charge-limit/releases/latest) and unzip it on your computer.

### Kobo

For Kobo devices I recommend installing [NickelMenu](https://pgaskin.net/NickelMenu/) if supported. Charge Limit still works without it, but then you have to change the settings in the config file.

1. Unzip `charge-limit-<version>-kobo.zip`. It contains `KoboRoot.tgz`.
2. Connect the Kobo over USB and copy `KoboRoot.tgz` into the Kobo's `.kobo/` folder. On a Mac, Finder hides folders starting with a dot: press **⌘⇧.** to show them.
3. Eject the Kobo. It installs the update and restarts.

After the restart, the limit is on at 80%. If your Kobo has NickelMenu, you will see **Charge ...** items, which you can use to check charging status and change settings. There will also be a `chargelimit/` folder at the top of the Kobo's storage, with the settings file `config`, where you can manually edit the limits, and the [diagnostics report](#reporting-a-problem).

### Kindle

Requires a jailbroken Kindle that can run scriptlets (current jailbreaks with the Universal Hotfix). No KUAL or KOReader needed.

#### 1. Extract the ZIP on your computer

Extract `charge-limit-<version>-kindle.zip`. It contains:

```text
documents/
└── chargelimit.sh              the Charge Limit scriptlet
extensions/
└── chargelimit/
    ├── install.sh
    ├── chargelimit.conf
    ├── 99-chargelimit.rules
    ├── runtime/                what Install puts on the Kindle
    └── ui/                     the app
```

#### 2. Copy the files to the Kindle

Connect the Kindle over USB and open its storage. Copy:

- `chargelimit.sh` into the Kindle's `documents/` folder
- the `chargelimit` folder into the Kindle's `extensions/` folder (create `extensions/` at the top of the storage if it isn't there)

Copy the contents, not the whole `documents/` or `extensions/` folders: replacing the Kindle's own folders would delete what's in them.

After copying, the Kindle's storage has:

```text
/ (Kindle storage)
├── documents/
│   └── chargelimit.sh
└── extensions/
    └── chargelimit/
        ├── install.sh
        ├── chargelimit.conf
        ├── 99-chargelimit.rules
        ├── runtime/
        └── ui/
```

#### 3. Install

Eject the Kindle and open **Charge Limit** from the library. The app opens and says whether this Kindle is supported. Tap **Install**. The button then reads **Installed**, and the limit is on at 80%.

Charge Limit then adds a `chargelimit/` folder at the top of the storage, with the settings file and the [diagnostics report](#reporting-a-problem).

---

## Usage

### On a Kobo

If you don't have NickelMenu, there won't be any additions to the UI: Charge Limit runs automatically. To change its settings, see [this](#the-settings-file).

With NickelMenu, its items show the current setting and what a tap does:

| Item | What it does |
|---|---|
| **Charge status** | The settings, battery level, whether it's plugged in, and what charging is doing |
| **Limit on - turn off** | Turns the limit off (charging to 100% like stock) or back on |
| **Limit 80% - set 90%** | Cycles the limit through 70, 80 and 90% |
| **On at restart - set off** | Whether the limit is on after every restart |
| **Full charge once** | Charges to 100% until you next unplug, then the limit applies again |
| **Charge activity** | Recent events: "Stopped charging at 80%", "Unplugged at 79%, charging allowed again" |
| **Charge diagnostics** | Shows the power chip and its driver, and saves the report for [support requests](#reporting-a-problem) |

### On a Kindle

Open **Charge Limit** from the library. Tap **Off** to turn off the limit, or tap **70%**, **80%**, or **90%** to turn it on at that percentage. Under **Charge limit at startup**, choose whether the limit turns on or off at the next boot. The selected option in each row has white text on a black background.

### The settings file

Every setting is in one file, which the menu and the app also change: `chargelimit/config` at the top of the reader's storage. You can edit it over USB; changes apply within 30 seconds of ejecting.

| Setting | Default | Meaning |
|---|---|---|
| `ENABLED` | 1 | 1: the limit is on. 0: off, the reader charges to 100% like stock. |
| `START` | 1 | What `ENABLED` becomes at every restart: 1 on, 0 off. |
| `LIMIT` | 80 | Stop charging at this %. Charging resumes 5% lower. |
| `FULL_CHARGE` | 0 | 1: charge to 100% until the charger is next unplugged, then back to 0. |
| `DIAGNOSE` | 0 | 1: save the diagnostics report, then back to 0. On a reader that isn't supported yet, it starts the [support test](#kobo-without-nickelmenu) instead. |
| `UNINSTALL` | 0 | 1: remove Charge Limit (see [Uninstalling](#uninstalling)). |

---

## Updating

- **Kobo:** install the new `KoboRoot.tgz` the same way. Your settings stay.
- **Kindle:** copy the new `chargelimit.sh` into `documents/` and the new `chargelimit` folder into `extensions/`, replacing the old ones, then open **Charge Limit**. The button reads **Install** again; tap it. Your settings stay.

**Install** also reappears on a Kindle if a firmware update removed Charge Limit's start at boot: tap it to repair.

---

## Uninstalling

- **Kobo:** set `UNINSTALL=1` in `chargelimit/config` and eject.
- **Kindle:** tap **Uninstall Charge Limit** in the app, then again to confirm, or set `UNINSTALL=1` in `chargelimit/config`.

Within a few seconds, Charge Limit switches charging back on and removes everything it added: its program files, its start-at-boot files, its menu items or app, and its `chargelimit/` folder.

---

## How it works

Charge Limit runs a small background program on the reader. It never changes how the chip charges, only whether it's allowed to:

- **Checking:** every 30 seconds, and right away whenever the charger is plugged in or out.
- **At the limit:** it switches charging off through the power chip's driver. The chip then powers the reader straight from the charger, so the battery holds its level instead of being drained and topped up.
- **5% below the limit:** it switches charging back on, and the battery charges up to the limit again.
- **Unplugged, limit off or uninstalled:** charging is back on, as on a stock reader.
- **Asleep:** plugged in, the reader wakes often enough (or stays awake) for the limit to apply; on a Kobo a wake alarm is a fallback.
- **At startup:** on a Kobo, the program and a rule that starts it come with the standard `KoboRoot.tgz` update; on a Kindle, **Install** adds a start-up job. The Kindle app talks to the program through a small server that only listens on the Kindle itself.

---

## Safety and recovery

Charge Limit only switches charging on and off; it doesn't change how the chip charges.

- **What it adds on a Kobo:** `/usr/local/chargelimit/`, `/etc/udev/rules.d/99-chargelimit.rules`, `chargelimit/` and, with NickelMenu, `.adds/nm/chargelimit`.
- **What it adds on a Kindle:** `documents/chargelimit.sh` and `extensions/chargelimit/` (what you copy), the app's entry in `/var/local/appreg.db` (when you first open it), and, when you tap **Install**, `chargelimit/`, `/var/local/chargelimit/`, `/etc/upstart/chargelimit.conf` and `/etc/udev/rules.d/99-chargelimit.rules`.
- **Charging comes back on** whenever you unplug, turn the limit off, or uninstall. A reader that's powered off always charges, since nothing runs to stop it.

---

## Known limitations

- **Powered off, the limit doesn't apply:** the chip charges a powered-off reader towards 100%. If you leave a Kobo plugged in for days, turn off its automatic power-off, or it will power off and charge fully.
- **The battery icon** doesn't show the held state: on a Kobo it shows no charging symbol while the charger powers the reader, and on a Kindle it only updates when you replug.
- **Firmware updates** may remove the start at boot. On a Kobo, install `KoboRoot.tgz` again; on a Kindle, open **Charge Limit** and tap **Install**.
- **After a restart,** the Kindle charges normally for about 100 seconds until Charge Limit has started.
- **Readers other than the tested ones** may work but haven't been tried; see [Supported e-readers](#supported-e-readers).

---

## Reporting a problem

[Open an issue](https://github.com/chengandre/ereader-charge-limit/issues/new) and say what happened; a sentence or two is enough. If you can, attach the diagnostics report: tap **Charge diagnostics**, connect the reader, and drag `diagnostics.log` from the `chargelimit/` folder at the top of its storage into the issue. It lists the reader's firmware and power hardware, Charge Limit's settings and its recent log; it doesn't contain the serial number. It's plain text, so you can read it first.

### Help add support for your e-reader

If Charge Limit doesn't support your e-reader yet, it offers a short diagnostics test, about 5 minutes, that aims to collect everything needed to add support for it, so that ideally you only have to run it once. During the test it switches charging off and on a few times to find out how your reader can be controlled; charging always comes back on. If the results aren't enough, we may ask you to try a test version afterwards.

Before you start:

- Install Charge Limit as described in [Installation](#installation). On an unsupported Kindle, **Install** stays greyed out; that's expected.
- Have a **wall charger** ready, not a computer: plugging into a computer starts USB mode instead of charging.
- The battery should be **below 90%**: a full battery doesn't charge, so the test can't tell what switches charging off.

#### Kindle

1. Open **Charge Limit** and tap **Charge diagnostics**.
2. Follow the screen, which updates by itself: unplug the charger if it's plugged in, plug in the wall charger, leave it plugged in while it tests (a few minutes), then unplug it when the screen says so.
3. When the screen says **Done**, connect the Kindle to your computer and attach `chargelimit/diagnostics.log` to an issue, with your Kindle's model.

#### Kobo with NickelMenu

The menu shows one message per tap, so tap **Charge diagnostics** again after each step to see the next one. Each message says what to do now and what comes next.

1. Unplug the charger, then tap **Charge diagnostics**. It says the test has started (step 1).
2. Plug in the wall charger, wait a few seconds, and tap **Charge diagnostics** again. It shows the test's progress (step 3); leave the charger plugged in and tap again every minute or so.
3. When it says to unplug (step 4), unplug, wait a few seconds and tap **Charge diagnostics** again.
4. When it says **Done**, connect the Kobo to your computer and attach `chargelimit/diagnostics.log` to an issue, with your Kobo's model.

#### Kobo without NickelMenu

Without NickelMenu the test runs without messages, so follow these timings:

1. Connect the Kobo to your computer, open `chargelimit/config` and set `DIAGNOSE=1`. Save, eject the Kobo and unplug it from the computer.
2. Wait **1 minute** with the Kobo unplugged, so the test can start. Then, within 5 minutes, plug in the wall charger and leave it plugged in for **10 minutes**.
3. Unplug it and wait a minute.
4. Connect the Kobo to your computer. When the test is done, `chargelimit/diagnostics.log` starts with "Charge Limit support report"; attach it to an issue, with your Kobo's model.

---

## Project structure

```text
src/chargectl.c            switches charging; the only part that touches hardware
core/                      shared by every reader
├── chargelimitd.sh        the background program
├── launch.sh              starts it, or tells it to check now
├── actions.sh             what each menu item or app button does
├── settings.sh            defaults, the settings file, menu labels
├── diagnostics.sh         the diagnostics report
├── support.sh             the guided test on a reader it can't control yet
└── config.default         the settings file's template
platforms/kobo/            KoboRoot.tgz: platform.sh, the udev rule, the developer menu
platforms/kindle/          the scriptlet, install.sh, platform.sh, the boot files
└── ui/                    the Kindle app, its launcher and its local server
build.sh                   builds both packages (run by GitHub Actions)
```

---

## Credits

- The [Clara BW KOReader charge limit plugin](https://github.com/jopidovba-a11y/Charge-Limit-For-Kobo-Clara-BW-Koreader-Plugin), for showing the driver's `charging` switch.
- [kindle-button-mapper-rs](https://github.com/zampierilucas/kindle-button-mapper-rs) by zampierilucas, for showing an HTML app on current firmware talking to a local helper.
- Kobo's published kernel source ([kobolabs/b300-sage](https://github.com/kobolabs/b300-sage)) and mainline Linux's ROHM BD71828 driver, for the chips' registers.

---

## License

[MIT](LICENSE). The `chargectl` program in the downloads includes the GNU C Library, under the LGPL 2.1; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
