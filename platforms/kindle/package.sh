#!/bin/sh
# Stage build/kindle/, copied to the top of the Kindle's storage:
# documents/chargelimit.sh and extensions/chargelimit/. Run by build.sh.
set -eu

root=build/kindle
pkg=$root/extensions/chargelimit
mkdir -p "$root/documents" "$pkg/runtime"
cp platforms/kindle/chargelimit.sh "$root/documents/"
cp platforms/kindle/install.sh platforms/kindle/chargelimit.conf \
	platforms/kindle/99-chargelimit.rules "$pkg/"
cp core/* platforms/kindle/platform.sh build/chargectl build/VERSION \
	THIRD_PARTY_NOTICES.md licenses/LGPL-2.1.txt "$pkg/runtime/"
cp -R platforms/kindle/ui "$pkg/"
echo "Staged build/kindle/"
