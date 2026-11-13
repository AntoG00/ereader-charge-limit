/*
 * chargectl: read or switch an e-reader's charging from userspace, with the
 * stock driver still bound to the PMIC.
 *
 *   chargectl status  key=value lines; exits 1 without a supported control
 *   chargectl on      allow charging (stock behaviour)
 *   chargectl off     stop charging; the reader runs from USB
 *
 * Methods:
 *   bq256xx   the separate TI charger's "charge_enabled" file (Kindle Scribe)
 *   sysfs     the battery's "charging" file (the BD7182x driver,
 *             bd71827-power, on Kobos and Kindles)
 *   wario     the MAX77696 charger's controls in Lab126's sysdev (Kindle
 *             Paperwhite 7th gen; drivers/power/max77696-charger.c)
 *   register  a known PMIC's charge-enable bit over I2C, when there's no
 *             "charging" file or writing it didn't take
 *
 * Maxim MAX77696, CHG_CNFG_00 MODE as the "mode" file shows it:
 *   5 DC-DC buck + charger (normal), 4 buck only, 0 both off.
 * Off is 4: the buck keeps powering the reader from USB while the battery
 * rests. The driver's own "charging"/"allow_charging" = 0 gives 0, which
 * runs the reader from the battery. On is "allow_charging" = 1, the
 * driver's path back to 5. The driver doesn't set MODE at boot, so a held
 * 4 can outlive a restart: callers switch it on before they stop.
 * Its battery driver (max77696-battery) reports mV and mA.
 *
 * ROHM BD71828 (mainline Linux rohm-bd71828.h):
 *   0x6F CHG_EN bit 0, 0x68 DCIN_STAT bit 0, 0x65 CHG_STATE bits 6:0
 * Ricoh RC5T619 (Kobo's b300-sage kernel source):
 *   0xB3 CHGCTL1 bits 1:0 (VUSB, VADP charge enable)
 *   0xBD CHGSTATE bits 7:6 supply state, bits 4:0 charge state
 *   0xFF BANKSEL
 *
 * The Ricoh driver caches its selected bank and uses bank 1 at runtime, so
 * we never write BANKSEL. Each access reads BANKSEL in the same I2C_RDWR
 * transfer, under the adapter lock; if bank 1 was active, the access is
 * undone and retried.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define REG_BANKSEL 0xFF
#define SUPPLIES "/sys/class/power_supply"
/* Sized for a 255-byte name and the longest suffix, so gcc can prove
 * snprintf never truncates. */
#define SUPPLY_DIR_LEN (sizeof(SUPPLIES) + 1 + 255)
#define SUPPLY_PATH_LEN (SUPPLY_DIR_LEN + 16)
#define BQ_CHARGE_ENABLED SUPPLIES "/bq256xx-charger/charge_enabled"
#define WARIO "/sys/devices/system/wario_charger/wario_charger0"
#define WARIO_MODE_ON "5"
#define WARIO_MODE_OFF "4"

#define RETRIES 20
#define RETRY_DELAY_US 50000

struct pmic {
	const char *name;	/* i2c client name in sysfs */
	uint8_t ctl_reg;	/* register holding the charge-enable bits */
	uint8_t en_bits;
	uint8_t dcin_reg;	/* charger present when (reg & dcin_mask) != 0 */
	uint8_t dcin_mask;
	uint8_t state_reg;	/* charge state = reg & state_mask */
	uint8_t state_mask;
	int banked;
};

static const struct pmic pmics[] = {
	{ "bd71828", 0x6F, 0x01, 0x68, 0x01, 0x65, 0x7F, 0 },
	{ "ricoh619", 0xB3, 0x03, 0xBD, 0xC0, 0xBD, 0x1F, 1 },
};

static const struct pmic *pmic;	/* NULL if no known PMIC */
static int fd;
static uint16_t addr;

static char battery[SUPPLY_DIR_LEN];	/* battery power_supply dir, "" if none */
static char charging_attr[SUPPLY_PATH_LEN];	/* its "charging" file, "" if none */
static int plugged;		/* another power_supply online, or MAX77696 connected */
static int milli_units;		/* the battery reports mV and mA, not uV and uA */
static int bq256xx;		/* the separate TI charger supplies the battery */
static int wario;		/* the MAX77696 charger's sysdev is there */

static uint8_t reg_banksel = REG_BANKSEL;

/* Exact names: the BD71828 also has "bd71828-otp" and "bd71828_h" clients. */
static void open_pmic(void)
{
	DIR *dir = opendir("/sys/bus/i2c/devices");
	struct dirent *de;
	int bus = -1;
	unsigned int a;

	if (!dir)
		return;
	while (bus < 0 && (de = readdir(dir))) {
		char path[300], name[32] = "";
		FILE *f;
		int b;

		if (sscanf(de->d_name, "%d-%4x", &b, &a) != 2)
			continue;
		snprintf(path, sizeof(path), "/sys/bus/i2c/devices/%s/name", de->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (fgets(name, sizeof(name), f)) {
			name[strcspn(name, "\n")] = '\0';
			for (size_t i = 0; i < sizeof(pmics) / sizeof(pmics[0]); i++) {
				if (strcmp(name, pmics[i].name) == 0) {
					pmic = &pmics[i];
					bus = b;
					addr = a;
				}
			}
		}
		fclose(f);
	}
	closedir(dir);
	if (bus < 0)
		return;

	/* Kindles have no /dev/i2c nodes: expected, so no message. */
	char dev[32];
	snprintf(dev, sizeof(dev), "/dev/i2c-%d", bus);
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		if (errno != ENOENT)
			perror(dev);
		pmic = NULL;
	}
}

/* Read the first line of a sysfs file, without the newline. */
static int read_line(const char *path, char *buf, size_t size)
{
	FILE *f = fopen(path, "r");
	int ok;

	if (!f)
		return -1;
	ok = fgets(buf, size, f) != NULL;
	fclose(f);
	if (!ok)
		return -1;
	buf[strcspn(buf, "\n")] = '\0';
	return 0;
}

/*
 * A battery with a "charging" file wins over one without (a Sage PowerCover
 * adds its own). Any other supply online means the reader is plugged in.
 */
static void find_supplies(void)
{
	DIR *dir = opendir(SUPPLIES);
	struct dirent *de;

	if (!dir)
		return;
	while ((de = readdir(dir))) {
		char path[SUPPLY_PATH_LEN], val[32];

		if (de->d_name[0] == '.')
			continue;
		snprintf(path, sizeof(path), SUPPLIES "/%s/type", de->d_name);
		if (read_line(path, val, sizeof(val)) < 0)
			continue;
		if (strcmp(val, "Battery") != 0) {
			snprintf(path, sizeof(path), SUPPLIES "/%s/online", de->d_name);
			if (read_line(path, val, sizeof(val)) == 0 && strcmp(val, "1") == 0)
				plugged = 1;
			continue;
		}
		snprintf(path, sizeof(path), SUPPLIES "/%s/charging", de->d_name);
		if (access(path, F_OK) == 0 && !charging_attr[0]) {
			snprintf(battery, sizeof(battery), SUPPLIES "/%s", de->d_name);
			snprintf(charging_attr, sizeof(charging_attr), "%s", path);
		} else if (!battery[0]) {
			snprintf(battery, sizeof(battery), SUPPLIES "/%s", de->d_name);
		}
	}
	closedir(dir);
	milli_units = strcmp(battery, SUPPLIES "/max77696-battery") == 0;
}

/* The MAX77696's "connected" (charger input present) is the plug: its
 * power_supply's "online" is the driver's charger-enabled flag. */
static void find_wario(void)
{
	char val[8];

	if (access(WARIO "/mode", F_OK) != 0)
		return;
	wario = 1;
	if (read_line(WARIO "/connected", val, sizeof(val)) == 0)
		plugged = strcmp(val, "1") == 0;
}

static const char *method(void)
{
	if (!battery[0])
		return "none";
	if (bq256xx)
		return "bq256xx";
	if (charging_attr[0])
		return "sysfs";
	if (wario)
		return "wario";
	return pmic ? "register" : "none";
}

/* One transfer. Callers start with the two BANKSEL messages, dropped on
 * chips without banks. */
static int xfer(struct i2c_msg *msgs, int n)
{
	if (!pmic->banked) {
		msgs += 2;
		n -= 2;
	}
	struct i2c_rdwr_ioctl_data data = { .msgs = msgs, .nmsgs = n };

	for (int i = 0; i < n; i++)
		msgs[i].addr = addr;
	if (ioctl(fd, I2C_RDWR, &data) != n) {
		perror("I2C_RDWR");
		return -1;
	}
	return 0;
}

/* Read a bank-0 register. Returns 1 if bank 1 was active (value invalid). */
static int read_reg(uint8_t reg, uint8_t *val)
{
	uint8_t bank = 0;
	struct i2c_msg msgs[] = {
		{ .flags = 0, .len = 1, .buf = &reg_banksel },
		{ .flags = I2C_M_RD, .len = 1, .buf = &bank },
		{ .flags = 0, .len = 1, .buf = &reg },
		{ .flags = I2C_M_RD, .len = 1, .buf = val },
	};

	if (xfer(msgs, 4) < 0)
		return -1;
	return bank != 0;
}

static int read_reg_retry(uint8_t reg, uint8_t *val)
{
	for (int i = 0; i < RETRIES; i++) {
		int r = read_reg(reg, val);
		if (r <= 0)
			return r;
		usleep(RETRY_DELAY_US);
	}
	fprintf(stderr, "PMIC stayed on bank 1, giving up\n");
	return -1;
}

/*
 * Write the control register, reading the bank and the old value in the
 * same transfer. Returns 1 (retry) after restoring a bank-1 byte.
 */
static int write_ctl(uint8_t val, uint8_t *before)
{
	uint8_t reg = pmic->ctl_reg, bank = 0, wbuf[2] = { reg, val };
	struct i2c_msg msgs[] = {
		{ .flags = 0, .len = 1, .buf = &reg_banksel },
		{ .flags = I2C_M_RD, .len = 1, .buf = &bank },
		{ .flags = 0, .len = 1, .buf = &reg },
		{ .flags = I2C_M_RD, .len = 1, .buf = before },
		{ .flags = 0, .len = 2, .buf = wbuf },
	};

	if (xfer(msgs, 5) < 0)
		return -1;
	if (bank == 0)
		return 0;

	uint8_t bank2, restore[2] = { reg, *before };
	struct i2c_msg undo[] = {
		{ .flags = 0, .len = 1, .buf = &reg_banksel },
		{ .flags = I2C_M_RD, .len = 1, .buf = &bank2 },
		{ .flags = 0, .len = 2, .buf = restore },
	};
	if (xfer(undo, 3) < 0 || bank2 != 1) {
		fprintf(stderr, "WARNING: wrote bank-1 reg 0x%02X and could not restore it "
				"(was 0x%02x); reboot to let the driver reinitialise\n", reg, *before);
		return -1;
	}
	return 1;
}

static uint8_t with_charging(uint8_t v, int enable)
{
	return enable ? (v | pmic->en_bits) : (v & ~pmic->en_bits);
}

static int write_attr(const char *path, const char *val)
{
	int afd = open(path, O_WRONLY);

	if (afd < 0) {
		perror(path);
		return -1;
	}
	ssize_t n = write(afd, val, strlen(val));
	close(afd);
	if (n != (ssize_t)strlen(val)) {
		perror(path);
		return -1;
	}
	return 0;
}

/* 1, 0, or -1 if unreadable. It reads 0 while unplugged, whatever CHG_EN. */
static int read_charging_attr(void)
{
	char val[8];

	if (read_line(charging_attr, val, sizeof(val)) < 0)
		return -1;
	return strcmp(val, "0") != 0;
}

/* Lab126's bq256xx driver reads CHG_CONFIG from the charger. */
static int read_bq_charge_enabled(void)
{
	char val[8];

	if (read_line(BQ_CHARGE_ENABLED, val, sizeof(val)) == 0) {
		if (strcmp(val, "1") == 0)
			return 1;
		if (strcmp(val, "0") == 0)
			return 0;
	}
	fprintf(stderr, "could not read " BQ_CHARGE_ENABLED "\n");
	return -1;
}

/* The driver accepts any write, so the mode read back is the check. */
static int set_wario(int enable)
{
	char mode[8];

	if (write_attr(enable ? WARIO "/allow_charging" : WARIO "/mode",
		       enable ? "1" : WARIO_MODE_OFF) == 0 &&
	    read_line(WARIO "/mode", mode, sizeof(mode)) == 0 &&
	    strcmp(mode, enable ? WARIO_MODE_ON : WARIO_MODE_OFF) == 0)
		return 0;
	fprintf(stderr, WARIO "/mode did not take effect\n");
	return -1;
}

/*
 * Prefer the driver's file, checked against the register when the PMIC is
 * known. In the register loop, a pass with nothing to do is the check.
 */
static int set_charging(int enable)
{
	if (bq256xx) {
		if (write_attr(BQ_CHARGE_ENABLED, enable ? "1" : "0") < 0)
			return -1;
		if (read_bq_charge_enabled() == enable)
			return 0;
		fprintf(stderr, BQ_CHARGE_ENABLED " did not take effect\n");
		return -1;
	}
	if (strcmp(method(), "wario") == 0)
		return set_wario(enable);
	if (charging_attr[0]) {
		uint8_t cur;
		const char *val = enable ? "1" : "0";

		if (!pmic) {
			/* Unplugged, the file can't be read back (see print_status). */
			if (write_attr(charging_attr, val) == 0 &&
			    (!plugged || read_charging_attr() == enable))
				return 0;
			fprintf(stderr, "%s did not take effect\n", charging_attr);
			return -1;
		}
		if (write_attr(charging_attr, val) == 0 &&
		    read_reg_retry(pmic->ctl_reg, &cur) == 0 &&
		    with_charging(cur, enable) == cur)
			return 0;
		fprintf(stderr, "%s did not take effect, writing the register directly\n",
			charging_attr);
	}

	for (int i = 0; i < RETRIES; i++) {
		uint8_t cur, before;

		if (read_reg_retry(pmic->ctl_reg, &cur) < 0)
			return -1;
		if (with_charging(cur, enable) == cur)
			return 0;

		int r = write_ctl(with_charging(cur, enable), &before);
		if (r < 0)
			return -1;
		if (r == 0 && before != cur) {
			/* The driver changed it between our read and write:
			 * reapply its value with our bit. */
			if (write_ctl(with_charging(before, enable), &before) < 0)
				return -1;
		}
		if (r == 1)
			usleep(RETRY_DELAY_US);
	}
	fprintf(stderr, "could not update charge control register\n");
	return -1;
}

/* A battery reading in micro units, scaled from milli where needed. */
static void print_micro(const char *key, const char *val)
{
	if (milli_units)
		printf("%s=%ld\n", key, strtol(val, NULL, 10) * 1000);
	else
		printf("%s=%s\n", key, val);
}

/*
 * method, pmic, battery, plugged, capacity, voltage_uv, current_ua,
 * charging_enabled; ctl, pmic_plugged and charge_state with a known PMIC;
 * charger_mode with the wario method.
 */
static int print_status(void)
{
	char path[SUPPLY_PATH_LEN], val[32];
	int enabled = -1;

	printf("method=%s\n", method());
	printf("pmic=%s\n", pmic ? pmic->name : "none");
	printf("battery=%s\n", battery);
	printf("plugged=%d\n", plugged);
	if (battery[0]) {
		snprintf(path, sizeof(path), "%s/capacity", battery);
		if (read_line(path, val, sizeof(val)) == 0)
			printf("capacity=%s\n", val);
		snprintf(path, sizeof(path), "%s/voltage_now", battery);
		if (read_line(path, val, sizeof(val)) == 0)
			print_micro("voltage_uv", val);
		/* Negative while discharging. current_avg lags by minutes. */
		snprintf(path, sizeof(path), "%s/current_now", battery);
		if (read_line(path, val, sizeof(val)) == 0)
			print_micro("current_ua", val);
	}
	if (bq256xx) {
		enabled = read_bq_charge_enabled();
	} else if (pmic) {
		uint8_t ctl, dcin, state;

		if (read_reg_retry(pmic->ctl_reg, &ctl) < 0 ||
		    read_reg_retry(pmic->dcin_reg, &dcin) < 0 ||
		    read_reg_retry(pmic->state_reg, &state) < 0)
			return -1;
		enabled = (ctl & pmic->en_bits) == pmic->en_bits;
		printf("ctl=0x%02x\n", ctl);
		printf("pmic_plugged=%d\n", (dcin & pmic->dcin_mask) != 0);
		printf("charge_state=0x%02x\n", state & pmic->state_mask);
	} else if (strcmp(method(), "wario") == 0) {
		if (read_line(WARIO "/mode", val, sizeof(val)) < 0)
			return -1;
		printf("charger_mode=%s\n", val);
		enabled = strcmp(val, WARIO_MODE_ON) == 0;
	} else if (charging_attr[0] && !plugged) {
		printf("charging_enabled=unknown\n");
		return 0;
	} else if (charging_attr[0]) {
		enabled = read_charging_attr();
	}
	if (enabled >= 0)
		printf("charging_enabled=%d\n", enabled);
	return strcmp(method(), "none") == 0 || enabled < 0 ? -1 : 0;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s status|on|off\n", argv[0]);
		return 2;
	}
	find_supplies();
	bq256xx = access(BQ_CHARGE_ENABLED, F_OK) == 0;
	/* With a separate charger, the ROHM charge bit cannot stop charging. */
	if (!bq256xx) {
		find_wario();
		open_pmic();
	}

	if (strcmp(argv[1], "status") == 0)
		return print_status() < 0;
	if (strcmp(argv[1], "on") != 0 && strcmp(argv[1], "off") != 0) {
		fprintf(stderr, "usage: %s status|on|off\n", argv[0]);
		return 2;
	}
	if (strcmp(method(), "none") == 0) {
		fprintf(stderr, "no supported charge control on this reader\n");
		return 1;
	}
	return set_charging(strcmp(argv[1], "on") == 0) < 0;
}
