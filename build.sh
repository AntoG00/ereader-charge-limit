#!/bin/sh
# Cross-compile chargectl (32-bit ARM, hard-float, static: it runs on the
# Kobo Sage and the Kindle Paperwhite 11th gen alike), then let each platform
# pack its package into build/: KoboRoot.tgz, and the Kindle folder kindle/.
# Needs Linux with gcc-arm-linux-gnueabihf and GNU tar; .github/workflows/build.yml
# runs this on GitHub's Ubuntu runners.
set -eu
cd "$(dirname "$0")"

rm -rf build && mkdir -p build
arm-linux-gnueabihf-gcc -static -Os -Wall -Wextra -Werror -o build/chargectl src/chargectl.c
arm-linux-gnueabihf-strip build/chargectl
# Logged at startup and in diagnostics, so reports say which build they came from.
git describe --always --dirty > build/VERSION

sh platforms/kobo/package.sh
sh platforms/kindle/package.sh
