#!/bin/sh
# Cross-compile kobo-chg for the Sage (32-bit ARM, hard-float) and pack
# build/KoboRoot.tgz. Needs Linux with gcc-arm-linux-gnueabihf and GNU tar;
# .github/workflows/build.yml runs this on GitHub's Ubuntu runners.
set -eu
cd "$(dirname "$0")"

rm -rf build && mkdir -p build/rootfs
cp -R rootfs/. build/rootfs/
arm-linux-gnueabihf-gcc -static -Os -Wall -Wextra -Werror \
	-o build/rootfs/usr/local/chargelimit/kobo-chg src/kobo-chg.c
arm-linux-gnueabihf-strip build/rootfs/usr/local/chargelimit/kobo-chg
chmod 755 build/rootfs/usr/local/chargelimit/*
# Logged at startup and in diagnostics, so reports say which build they came from.
git describe --always --dirty > build/rootfs/usr/local/chargelimit/VERSION
chmod 644 build/rootfs/usr/local/chargelimit/VERSION build/rootfs/etc/udev/rules.d/99-chargelimit.rules

# List only our own paths so extracting over / never touches the modes of
# existing directories like /etc or /usr.
tar -czf build/KoboRoot.tgz -C build/rootfs --owner=0 --group=0 \
	etc/udev/rules.d/99-chargelimit.rules usr/local/chargelimit
echo "Built build/KoboRoot.tgz"
