#!/bin/sh
# Cross-compile chargectl (32-bit ARM, hard-float, static: it runs on the
# Kobo Sage and the Kindle Paperwhite 11th gen alike), then let each platform
# pack its package into build/: KoboRoot.tgz, and the Kindle folder kindle/.
# Needs Linux with gcc-arm-linux-gnueabihf, GNU tar and zip;
# .github/workflows/build.yml runs this on GitHub's Ubuntu runners.
set -eu
cd "$(dirname "$0")"

rm -rf build && mkdir -p build
arm-linux-gnueabihf-gcc -static -Os -Wall -Wextra -Werror -o build/chargectl src/chargectl.c
arm-linux-gnueabihf-strip build/chargectl
# The version comes from CI (.github/workflows/build.yml): 1.2.3 for the
# release tag v1.2.3, otherwise 0.0.<run number>; a local build is "dev".
# build/VERSION adds the commit, as in "0.0.42 (71b835b)": the daemon logs it
# at startup, diagnostics report it, the Kindle app shows it, and the
# Kindle's install --check compares it.
version=${VERSION:-dev}
echo "$version ($(git rev-parse --short HEAD))" > build/VERSION

sh platforms/kobo/package.sh
sh platforms/kindle/package.sh

# What users download, one folder and one ZIP per reader, each laid out as
# its files go on the reader's storage:
#   build/dist/charge-limit-<version>-kobo/.kobo/KoboRoot.tgz
#   build/dist/charge-limit-<version>-kindle/{documents,chargelimit}/
# CI uploads the folders as artifacts and attaches the ZIPs to releases.
kobo=charge-limit-$version-kobo
kindle=charge-limit-$version-kindle
mkdir -p "build/dist/$kobo/.kobo"
cp build/KoboRoot.tgz "build/dist/$kobo/.kobo/"
cp -R build/kindle "build/dist/$kindle"
(cd "build/dist/$kobo" && zip -qr "../$kobo.zip" .kobo)
(cd "build/dist/$kindle" && zip -qr "../$kindle.zip" documents chargelimit)
echo "Built build/dist/$kobo.zip and build/dist/$kindle.zip"
