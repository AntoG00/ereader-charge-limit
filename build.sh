#!/bin/sh
# Build chargectl (static ARM hard-float, for Kobos and Kindles alike) and
# both packages. Needs Linux with gcc-arm-linux-gnueabihf and GNU tar.
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

# The downloads, one folder per reader (CI zips them):
#   build/dist/charge-limit-<version>-kobo/KoboRoot.tgz
#   build/dist/charge-limit-<version>-kindle/{documents,extensions}/
mkdir -p "build/dist/charge-limit-$version-kobo"
cp build/KoboRoot.tgz "build/dist/charge-limit-$version-kobo/"
cp -R build/kindle "build/dist/charge-limit-$version-kindle"
echo "Built build/dist/"
