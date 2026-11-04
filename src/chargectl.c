/*
 * chargectl: read or toggle an e-reader's charge enable from userspace, while
 * the stock driver stays bound to the PMIC.
 *
 *   chargectl status  prints shell-evaluable key=value lines; exits 1 if
 *                     this reader has no supported charge control
 *   chargectl on      allow charging (stock behaviour)
 *   chargectl off     stop charging; the device keeps running from USB
 *
 * Two ways to control charging, chosen by what the reader offers:
 *
 *   sysfs     the battery power_supply has a "charging" file (the
 *             bd71827-power driver on BD7182x readers, in Kobos and
 *             Kindles). The driver does the register update under its own
 *             lock.
 *   register  a known PMIC on I2C, found by its driver's name. Used when
 *             there's no "charging" file, or when writing it didn't take.
 *
 * Battery level, voltage and "plugged" always come from the power_supply
 * class, so they work on any reader. Known PMICs:
 *
 * ROHM BD71828 (seen on a retail Sage; registers from mainline Linux's
 * rohm-bd71828.h and bd71828-power.c, which maps "inhibit-charge" to
 * clearing CHG_EN):
 *   0x6F CHG_EN     bit0 = charge enable
 *   0x68 DCIN_STAT  bit0 = charger present
 *   0x65 CHG_STATE  bits 6:0 = charge state
 *
 * Ricoh RC5T619 (in Kobo's published b300-sage kernel source):
 *   0xB3 CHGCTL1   bit0 = VADP charge enable, bit1 = VUSB charge enable
 *   0xBD CHGSTATE  bits 7:6 = supply state (0 = battery only),
 *                  bits 4:0 = charge state
 *   0xFF BANKSEL   0 or 1
 *
 * The Ricoh bank problem: the driver caches which bank it last selected
 * and only rewrites BANKSEL when it needs the other one. It uses bank 1 at
 * runtime (fuel-gauge upkeep), so we must never change BANKSEL ourselves,
 * and a plain write to 0xB3 while bank 1 is active would land on a
 * fuel-gauge register. Every Ricoh access therefore reads BANKSEL inside
 * the same I2C_RDWR transfer as the register access. The adapter lock is
 * held for the whole transfer, so the bank we read is the bank the access
 * used. If it was bank 1 we undo the access and retry. The BD71828 has a
 * single register page, so its transfers skip the BANKSEL messages.
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
/*
 * SUPPLIES + "/" + a name of up to 255 bytes + NUL, and room for the longest
 * attribute suffix ("/voltage_now"). Sized so gcc can prove snprintf never
 * truncates.
 */
#define SUPPLY_DIR_LEN (sizeof(SUPPLIES) + 1 + 255)
#define SUPPLY_PATH_LEN (SUPPLY_DIR_LEN + 16)

#define RETRIES 20
#define RETRY_DELAY_US 50000

struct pmic {
	const char *name;	/* i2c client name in sysfs */
	uint8_t ctl_reg;	/* register holding the charge-enable bits */
	uint8_t en_bits;
	uint8_t dcin_reg;	/* charger present when (reg & dcin_mask) != 0;
				   reported for comparison with sysfs "plugged" */
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
static int plugged;		/* some other power_supply is online */

static uint8_t reg_banksel = REG_BANKSEL;

/*
 * Find the PMIC on the I2C bus by the name its driver binds to. Names must
 * match exactly: the BD71828 also has a "bd71828-otp" client.
 */
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

	/*
	 * Kindles have the BD71828 but no /dev/i2c nodes: no register access,
	 * which is expected there and not worth a message on every call.
	 */
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
 * Pick the battery power_supply and work out whether a charger is online.
 * A Battery-type supply with a "charging" file wins over one without (a
 * Sage PowerCover, for one, adds its own battery). Any other supply that
 * reports online=1 means the reader is plugged in.
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
}

static const char *method(void)
{
	if (!battery[0])
		return "none";
	if (charging_attr[0])
		return "sysfs";
	return pmic ? "register" : "none";
}

/*
 * Send msgs as one transfer. Every caller starts with the two BANKSEL
 * messages; they are dropped on chips without banks.
 */
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
 * Write the charge-control register in one transfer that also reports the
 * active bank and the register's value just before the write. If bank 1
 * was active, put the clobbered bank-1 byte back and report a retry.
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

static int write_charging_attr(int enable)
{
	int afd = open(charging_attr, O_WRONLY);

	if (afd < 0) {
		perror(charging_attr);
		return -1;
	}
	ssize_t n = write(afd, enable ? "1" : "0", 1);
	close(afd);
	if (n != 1) {
		perror(charging_attr);
		return -1;
	}
	return 0;
}

/*
 * The "charging" file's value: 1, 0, or -1 if unreadable. On the BD71828
 * Sage it follows CHG_EN only while a charger is connected and reads 0
 * when unplugged, so with a known PMIC the register is the truth.
 */
static int read_charging_attr(void)
{
	char val[8];

	if (read_line(charging_attr, val, sizeof(val)) < 0)
		return -1;
	return strcmp(val, "0") != 0;
}

/*
 * Prefer the driver's file, checked against the register when the PMIC is
 * known, or against the file itself when it isn't. In the direct-write loop
 * each pass re-reads the register, so a pass that finds nothing to do is
 * the verification.
 */
static int set_charging(int enable)
{
	if (charging_attr[0]) {
		uint8_t cur;

		if (!pmic) {
			/* Unplugged, the file can't be read back (see print_status). */
			if (write_charging_attr(enable) == 0 &&
			    (!plugged || read_charging_attr() == enable))
				return 0;
			fprintf(stderr, "%s did not take effect\n", charging_attr);
			return -1;
		}
		if (write_charging_attr(enable) == 0 &&
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
			/*
			 * The driver changed the register between our read and
			 * write, and our write discarded its change. Reapply its
			 * value with our bits on top.
			 */
			if (write_ctl(with_charging(before, enable), &before) < 0)
				return -1;
		}
		if (r == 1)
			usleep(RETRY_DELAY_US);
	}
	fprintf(stderr, "could not update charge control register\n");
	return -1;
}

/*
 * Example on a BD71828 Sage:
 *   method=sysfs pmic=bd71828 battery=/sys/class/power_supply/battery
 *   charging_enabled=1 plugged=1 capacity=84 voltage_uv=4119300
 *   current_ua=402000 ctl=0x01 pmic_plugged=1 charge_state=0x0e
 * (one key per line). The last three only appear with a known PMIC.
 * Without one, charging_enabled comes from the "charging" file, and is
 * "unknown" while unplugged.
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
			printf("voltage_uv=%s\n", val);
		/* Negative while discharging. current_now rather than current_avg:
		 * on the BD71828 Sage the average lagged by minutes, missing a
		 * full backlight and the switch to charging. */
		snprintf(path, sizeof(path), "%s/current_now", battery);
		if (read_line(path, val, sizeof(val)) == 0)
			printf("current_ua=%s\n", val);
	}
	if (pmic) {
		uint8_t ctl, dcin, state;

		if (read_reg_retry(pmic->ctl_reg, &ctl) < 0 ||
		    read_reg_retry(pmic->dcin_reg, &dcin) < 0 ||
		    read_reg_retry(pmic->state_reg, &state) < 0)
			return -1;
		enabled = (ctl & pmic->en_bits) == pmic->en_bits;
		printf("ctl=0x%02x\n", ctl);
		printf("pmic_plugged=%d\n", (dcin & pmic->dcin_mask) != 0);
		printf("charge_state=0x%02x\n", state & pmic->state_mask);
	} else if (charging_attr[0] && !plugged) {
		/* The file reads 0 when unplugged whatever the setting. */
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
	open_pmic();

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
