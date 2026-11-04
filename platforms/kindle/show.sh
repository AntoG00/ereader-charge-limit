# Sourced by the scriptlets: show text full screen for a while, then hand the
# screen back to the Kindle UI.
#
#   "$DIR/actions.sh" status 2>&1 | show 10
#
# The scriptlet runner only shows a script's output for about a second, so
# the scriptlets say "# DontUseFBInk" and draw with the Kindle's own eips. The
# Kindle UI repaints over text drawn once within a second, so it's drawn
# again every 2 s, with a countdown. The screen isn't closed by a tap: the
# Kindle UI underneath would get the tap too, on a book or scriptlet you
# can't see. eips stops drawing a line at "%", and no escape (%%, \%) gets
# one through, so it's spelled out: "80%" is shown as "80 percent".

# Columns per line; longer lines wrap at a space.
SHOW_WIDTH=40

show() {
	text=$(sed 's/%/ percent/g')
	if command -v fold >/dev/null; then
		text=$(printf '%s\n' "$text" | fold -s -w "$SHOW_WIDTH")
	fi
	eips -c >/dev/null
	left=$1
	while [ "$left" -gt 0 ]; do
		row=2
		while IFS= read -r line; do
			eips 2 "$row" "$line" >/dev/null
			row=$((row + 1))
		done <<EOF
$text
EOF
		# Padded, so a shorter number covers the longer one before it.
		eips 2 $((row + 1)) "(closes in $left s)  " >/dev/null
		sleep 2
		left=$((left - 2))
	done
	DISPLAY=:0 xrefresh 2>/dev/null || eips -c >/dev/null
}
