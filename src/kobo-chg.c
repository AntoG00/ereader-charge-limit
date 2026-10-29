/*
 * kobo-chg: read or toggle the Kobo Sage's charger-enable bit(s) on its
 * PMIC from userspace, while the stock driver stays bound to the chip.
 *
 *   kobo-chg status   prints shell-evaluable key=value lines
 *   kobo-chg on       allow charging (stock behaviour)
 *   kobo-chg off      stop charging; the device keeps running from USB
 *
 * Sages ship with one of two PMICs, found by the name in sysfs:
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
 *
 * Direct register writes are the fallback. Kobo's bd71827-power driver
 * exposes the BD71828's CHG_EN bit as CHARGING_ATTR (the same file Kobo's
 * other BD7182x readers have), and "on"/"off" write that file whenever it
 * exists, so the driver does the register update under its own lock. The
 * register is read back either way, and written directly if the bit didn't
 * follow. The published Ricoh driver has no such file, so on that chip the
 * file is only used if a newer driver adds it.
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
#define CHARGING_ATTR "/sys/class/power_supply/battery/charging"

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

static const struct pmic *pmic;
static int fd;
static uint16_t addr;

static uint8_t reg_banksel = REG_BANKSEL;

/*
 * Find the PMIC on the I2C bus by the name its driver binds to. Names must
 * match exactly: the BD71828 also has a "bd71828-otp" client.
 */
static int open_pmic(void)
{
	DIR *dir = opendir("/sys/bus/i2c/devices");
	struct dirent *de;
	int bus = -1;
	unsigned int a;

	if (!dir) {
		perror("opendir /sys/bus/i2c/devices");
		return -1;
	}
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
	if (bus < 0) {
		fprintf(stderr, "no bd71828 or ricoh619 PMIC under /sys/bus/i2c/devices\n");
		return -1;
	}

	char dev[32];
	snprintf(dev, sizeof(dev), "/dev/i2c-%d", bus);
	fd = open(dev, O_RDWR);
	if (fd < 0) {
		perror(dev);
		return -1;
	}
	return 0;
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
	int afd = open(CHARGING_ATTR, O_WRONLY);

	if (afd < 0) {
		perror(CHARGING_ATTR);
		return -1;
	}
	ssize_t n = write(afd, enable ? "1" : "0", 1);
	close(afd);
	if (n != 1) {
		perror(CHARGING_ATTR);
		return -1;
	}
	return 0;
}

/*
 * Prefer the driver's file; the register is read back either way. In the
 * direct-write loop each pass re-reads the register, so a pass that finds
 * nothing to do is the verification.
 */
static int set_charging(int enable)
{
	if (access(CHARGING_ATTR, F_OK) == 0) {
		uint8_t cur;

		if (write_charging_attr(enable) == 0 &&
		    read_reg_retry(pmic->ctl_reg, &cur) == 0 &&
		    with_charging(cur, enable) == cur)
			return 0;
		fprintf(stderr, "%s did not take effect, writing the register directly\n",
			CHARGING_ATTR);
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

static int print_status(void)
{
	uint8_t ctl, dcin, state;

	if (read_reg_retry(pmic->ctl_reg, &ctl) < 0 ||
	    read_reg_retry(pmic->dcin_reg, &dcin) < 0 ||
	    read_reg_retry(pmic->state_reg, &state) < 0)
		return -1;
	printf("pmic=%s\n", pmic->name);
	printf("ctl=0x%02x\n", ctl);
	printf("charging_enabled=%d\n", (ctl & pmic->en_bits) == pmic->en_bits);
	printf("plugged=%d\n", (dcin & pmic->dcin_mask) != 0);
	printf("charge_state=0x%02x\n", state & pmic->state_mask);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s status|on|off\n", argv[0]);
		return 2;
	}
	if (open_pmic() < 0)
		return 1;

	if (strcmp(argv[1], "status") == 0)
		return print_status() < 0;
	if (strcmp(argv[1], "on") == 0)
		return set_charging(1) < 0;
	if (strcmp(argv[1], "off") == 0)
		return set_charging(0) < 0;

	fprintf(stderr, "usage: %s status|on|off\n", argv[0]);
	return 2;
}
