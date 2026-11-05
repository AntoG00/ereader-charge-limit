#!/bin/sh
# Build chargectl (static ARM hard-float, for Kobos and Kindles alike) and
# both packages. Needs Linux with gcc-arm-linux-gnueabihf, GNU tar and zip.
set -eu
cd "$(dirname "$0")"

rm -rf build && mkdir -p build
arm-linux-gnueabihf-gcc -static -Os -Wall -Wextra -Werror -o build/chargectl src/chargectl.c
arm-linux-gnueabihf-strip build/chargectl
# VERSION comes from CI; build/VERSION adds the commit: "0.0.42 (71b835b)".
version=${VERSION:-dev}
echo "$version ($(git rev-parse --short HEAD))" > build/VERSION

sh platforms/kobo/package.sh
sh platforms/kindle/package.sh

# The downloads, laid out as they go on the reader:
#   build/dist/charge-limit-<version>-kobo/.kobo/KoboRoot.tgz
#   build/dist/charge-limit-<version>-kindle/{documents,extensions}/
kobo=charge-limit-$version-kobo
kindle=charge-limit-$version-kindle
mkdir -p "build/dist/$kobo/.kobo"
cp build/KoboRoot.tgz "build/dist/$kobo/.kobo/"
cp -R build/kindle "build/dist/$kindle"
(cd "build/dist/$kobo" && zip -qr "../$kobo.zip" .kobo)
(cd "build/dist/$kindle" && zip -qr "../$kindle.zip" documents extensions)
echo "Built build/dist/$kobo.zip and build/dist/$kindle.zip"
