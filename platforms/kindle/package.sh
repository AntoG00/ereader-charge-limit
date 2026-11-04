#!/bin/sh
# Stage the Kindle package in build/kindle/ from the core, this platform's
# files and the chargectl and VERSION that build.sh left in build/. Its
# contents are copied to the top of the Kindle's storage:
#
#   documents/chargelimit.sh   "Charge limit", opens the app
#   chargelimit/install/       install.sh, the boot files, runtime/ (what
#                              gets installed) and ui/ (the app and bridge,
#                              run from here)
#
# Run from the repository root.
set -eu

root=build/kindle
inst=$root/chargelimit/install
mkdir -p "$root/documents" "$inst/runtime"
cp platforms/kindle/chargelimit.sh "$root/documents/"
cp platforms/kindle/install.sh platforms/kindle/chargelimit.conf \
	platforms/kindle/99-chargelimit.rules "$inst/"
cp core/* platforms/kindle/platform.sh build/chargectl build/VERSION "$inst/runtime/"
cp -R platforms/kindle/ui "$inst/"
echo "Staged build/kindle/"
