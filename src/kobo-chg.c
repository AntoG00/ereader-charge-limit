/*
 * kobo-chg: read or toggle the Kobo Sage's charger-enable bits on the
 * Ricoh RC5T619 PMIC from userspace, while the stock ricoh619 driver
 * stays bound to the chip.
 *
 *   kobo-chg status   prints shell-evaluable key=value lines
 *   kobo-chg on       allow charging (stock behaviour)
 *   kobo-chg off      stop charging; the device keeps running from USB
 *
 * Registers (bank 0), from Kobo's b300-sage kernel source:
 *   0xB3 CHGCTL1   bit0 = VADP charge enable, bit1 = VUSB charge enable
 *   0xBD CHGSTATE  bits 7:6 = supply state (0 = battery only),
 *                  bits 4:0 = charge state
 *   0xFF BANKSEL   0 or 1
 *
 * The bank problem: the driver caches which bank it last selected and
 * only rewrites BANKSEL when it needs the other one. It uses bank 1 at
 * runtime (fuel-gauge upkeep), so we must never change BANKSEL ourselves,
 * and a plain write to 0xB3 while bank 1 is active would land on a
 * fuel-gauge register. Every access therefore reads BANKSEL inside the
 * same I2C_RDWR transfer as the register access. The adapter lock is
 * held for the whole transfer, so the bank we read is the bank the
 * access used. If it was bank 1 we undo the access and retry.
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

#define REG_CHGCTL1 0xB3
#define REG_CHGSTATE 0xBD
#define REG_BANKSEL 0xFF
#define CHG_EN_BITS 0x03

#define RETRIES 20
#define RETRY_DELAY_US 50000

static int fd;
static uint16_t addr;

static uint8_t reg_banksel = REG_BANKSEL;

/* Find the PMIC on the I2C bus by the name the ricoh619 driver binds to. */
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
	while ((de = readdir(dir))) {
		char path[300], name[32] = "";
		FILE *f;
		int b;

		if (sscanf(de->d_name, "%d-%4x", &b, &a) != 2)
			continue;
		snprintf(path, sizeof(path), "/sys/bus/i2c/devices/%s/name", de->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (fgets(name, sizeof(name), f) && strncmp(name, "ricoh619", 8) == 0) {
			bus = b;
			addr = a;
		}
		fclose(f);
		if (bus >= 0)
			break;
	}
	closedir(dir);
	if (bus < 0) {
		fprintf(stderr, "ricoh619 PMIC not found under /sys/bus/i2c/devices\n");
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

static int xfer(struct i2c_msg *msgs, int n)
{
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
	uint8_t bank;
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
 * Write CHGCTL1 in one transfer that also reports the active bank and the
 * register's value just before the write. If bank 1 was active, put the
 * clobbered bank-1 byte back and report a retry.
 */
static int write_chgctl1(uint8_t val, uint8_t *before)
{
	uint8_t reg = REG_CHGCTL1, bank, wbuf[2] = { REG_CHGCTL1, val };
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

	uint8_t bank2, restore[2] = { REG_CHGCTL1, *before };
	struct i2c_msg undo[] = {
		{ .flags = 0, .len = 1, .buf = &reg_banksel },
		{ .flags = I2C_M_RD, .len = 1, .buf = &bank2 },
		{ .flags = 0, .len = 2, .buf = restore },
	};
	if (xfer(undo, 3) < 0 || bank2 != 1) {
		fprintf(stderr, "WARNING: wrote bank-1 reg 0xB3 and could not restore it "
				"(was 0x%02x); reboot to let the driver reinitialise\n", *before);
		return -1;
	}
	return 1;
}

static uint8_t with_charging(uint8_t v, int enable)
{
	return enable ? (v | CHG_EN_BITS) : (v & ~CHG_EN_BITS);
}

/* Each pass re-reads CHGCTL1, so a pass that finds nothing to do is the verification. */
static int set_charging(int enable)
{
	for (int i = 0; i < RETRIES; i++) {
		uint8_t cur, before;

		if (read_reg_retry(REG_CHGCTL1, &cur) < 0)
			return -1;
		if (with_charging(cur, enable) == cur)
			return 0;

		int r = write_chgctl1(with_charging(cur, enable), &before);
		if (r < 0)
			return -1;
		if (r == 0 && before != cur) {
			/*
			 * The driver changed CHGCTL1 between our read and write,
			 * and our write discarded its change. Reapply its value
			 * with our bits on top.
			 */
			if (write_chgctl1(with_charging(before, enable), &before) < 0)
				return -1;
		}
		if (r == 1)
			usleep(RETRY_DELAY_US);
	}
	fprintf(stderr, "could not update CHGCTL1\n");
	return -1;
}

static int print_status(void)
{
	uint8_t ctl, state;

	if (read_reg_retry(REG_CHGCTL1, &ctl) < 0 ||
	    read_reg_retry(REG_CHGSTATE, &state) < 0)
		return -1;
	printf("chgctl1=0x%02x\n", ctl);
	printf("chgstate=0x%02x\n", state);
	printf("charging_enabled=%d\n", (ctl & CHG_EN_BITS) == CHG_EN_BITS);
	printf("plugged=%d\n", (state >> 6) != 0);
	printf("charge_state=%d\n", state & 0x1F);
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
