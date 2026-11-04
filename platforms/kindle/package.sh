#!/bin/sh
# Stage the Kindle package in build/kindle/ from the core, this platform's
# files and the chargectl and VERSION that build.sh left in build/. Its
# contents are copied to the top of the Kindle's storage:
#
#   documents/chargelimit-install.sh   "Charge install", the only item at first
#   chargelimit/install/               what it installs (see install.sh)
#
# Run from the repository root.
set -eu

root=build/kindle
inst=$root/chargelimit/install
mkdir -p "$root/documents" "$inst/scriptlets" "$inst/runtime"
cp platforms/kindle/chargelimit-install.sh "$root/documents/"
cp platforms/kindle/install.sh platforms/kindle/chargelimit.conf \
	platforms/kindle/99-chargelimit.rules "$inst/"
cp core/* platforms/kindle/platform.sh platforms/kindle/show.sh \
	build/chargectl build/VERSION "$inst/runtime/"

# One scriptlet per action, like the Kobo's menu items: file, library title,
# action (actions.sh), seconds on screen.
while IFS=: read -r file title action seconds; do
	cat > "$inst/scriptlets/$file.sh" <<EOF
#!/bin/sh
# Name: $title
# DontUseFBInk
#
# Installed by chargelimit; uninstalling removes it.

DIR=/var/local/chargelimit
[ -f "\$DIR/actions.sh" ] || exit 1
. "\$DIR/show.sh"
"\$DIR/actions.sh" $action 2>&1 | show $seconds
EOF
done <<EOF
chargelimit-status:Charge status:status:10
chargelimit-toggle:Charge limit - turn on or off:toggle:5
chargelimit-limit:Charge limit - change %:limit:5
chargelimit-start:Charge at restart - on or off:start:5
chargelimit-full:Charge to 100% once - or cancel:full:5
chargelimit-activity:Charge activity:activity:10
chargelimit-diagnose:Charge diagnostics:diagnose:5
EOF
echo "Staged build/kindle/"
