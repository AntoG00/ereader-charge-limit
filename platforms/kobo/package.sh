#!/bin/sh
# Pack build/KoboRoot.tgz, which the Kobo extracts over /. Run by build.sh.
set -eu

root=build/kobo
dir=$root/usr/local/chargelimit
mkdir -p "$dir" "$root/etc/udev/rules.d"
cp core/* platforms/kobo/platform.sh build/chargectl build/VERSION \
	THIRD_PARTY_NOTICES.md licenses/LGPL-2.1.txt "$dir/"
cp platforms/kobo/99-chargelimit.rules "$root/etc/udev/rules.d/"
chmod 755 "$dir"/*
chmod 644 "$dir/VERSION" "$dir/config.default" "$dir/settings.sh" "$dir/platform.sh" \
	"$dir/THIRD_PARTY_NOTICES.md" "$dir/LGPL-2.1.txt" \
	"$root/etc/udev/rules.d/99-chargelimit.rules"

# Only our own paths, so the modes of /etc and /usr stay untouched.
tar -czf build/KoboRoot.tgz -C "$root" --owner=0 --group=0 \
	etc/udev/rules.d/99-chargelimit.rules usr/local/chargelimit
echo "Built build/KoboRoot.tgz"
