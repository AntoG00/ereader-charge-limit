#!/bin/sh
# Pack build/KoboRoot.tgz from the core, this platform's files and the
# chargectl and VERSION that build.sh left in build/. Kobo's firmware extracts
# it over / and reboots. Run from the repository root.
set -eu

root=build/kobo
dir=$root/usr/local/chargelimit
mkdir -p "$dir" "$root/etc/udev/rules.d"
cp core/* platforms/kobo/platform.sh build/chargectl build/VERSION "$dir/"
cp platforms/kobo/99-chargelimit.rules "$root/etc/udev/rules.d/"
chmod 755 "$dir"/*
chmod 644 "$dir/VERSION" "$dir/config.default" "$dir/settings.sh" "$dir/platform.sh" \
	"$root/etc/udev/rules.d/99-chargelimit.rules"

# List only our own paths so extracting over / never touches the modes of
# existing directories like /etc or /usr.
tar -czf build/KoboRoot.tgz -C "$root" --owner=0 --group=0 \
	etc/udev/rules.d/99-chargelimit.rules usr/local/chargelimit
echo "Built build/KoboRoot.tgz"
