#!/usr/bin/env bash
# Check that an assembled e05.app contains what it is supposed to.
#
# Usage: verify_bundle.sh <path-to-e05.app>
#
# build_app.sh is a sequence of copies, rsyncs and edits, and its failure
# mode is silence: a step that finds nothing to do leaves the bundle a
# little emptier and exits 0. Three bugs have shipped that way — the
# resource bundle the app loaded only on the build machine, the Sparkle
# rpath that made the release die at launch, and a `source` line injected
# below an `exit`, which no test noticed because none of them looked at
# an assembled bundle.
#
# Everything here is an invariant of the product, not of the build: what
# the app opens at runtime, and what the shells in its panes read.
set -euo pipefail

APP="${1:?usage: verify_bundle.sh <path-to-e05.app>}"
C="$APP/Contents"
fail=0

bad() {
  printf 'verify_bundle: %s\n' "$1" >&2
  fail=1
}

exists() { [ -e "$2" ] || bad "$1 missing: ${2#"$APP"/}"; }
runnable() {
  [ -x "$2" ] || bad "$1 not executable: ${2#"$APP"/}"
}
contains() {
  grep -q -- "$3" "$2" 2> /dev/null || bad "$1: '$3' not in ${2#"$APP"/}"
}

exists "app binary" "$C/MacOS/e05"
runnable "app binary" "$C/MacOS/e05"
exists "Info.plist" "$C/Info.plist"

# The CLI the `open` shim hands off to, the shim itself, and the snippets
# the shells source. All four are read by name at runtime, so a rename
# upstream turns into a silent no-op rather than a build failure.
for f in e05 open e05-integration.zsh e05-integration.bash e05-integration.fish; do
  exists "bundled bin/$f" "$C/Resources/bin/$f"
done
runnable "bundled CLI" "$C/Resources/bin/e05"
runnable "open shim" "$C/Resources/bin/open"

# The adblock runtimes. `Bundle.module` resolved these to the build
# machine's .build directory once, so the app ran only there.
for f in cosmetic-runtime.js scriptlets.js; do
  exists "web runtime" "$C/Resources/$f"
done

exists "ghostty resources" "$C/Resources/ghostty/shell-integration"
exists "ghostty themes" "$C/Resources/ghostty/themes"
exists "terminfo" "$C/Resources/terminfo"
exists "app icon" "$C/Resources/AppIcon.icns"
exists "asset catalog" "$C/Resources/Assets.car"

# The injection, checked on the shipped file rather than on a copy the
# tests made. Each shell has to see the line; fish additionally has to
# see it above the call that ends the file with `exit 0`.
INTEG="$C/Resources/ghostty/shell-integration"
contains "zsh integration" "$INTEG/zsh/ghostty-integration" 'e05-integration.zsh'
contains "bash integration" "$INTEG/bash/ghostty.bash" 'e05-integration.bash'
FISH="$INTEG/fish/vendor_conf.d/ghostty-shell-integration.fish"
contains "fish integration" "$FISH" 'e05-integration.fish'
if [ -f "$FISH" ]; then
  e05_line=$(grep -n 'e05-integration.fish' "$FISH" | tail -1 | cut -d: -f1)
  exit_line=$(grep -n '^ghostty_exit$' "$FISH" | tail -1 | cut -d: -f1)
  if [ -z "$exit_line" ]; then
    bad "fish integration: no trailing 'ghostty_exit' to sit above"
  elif [ "$e05_line" -gt "$exit_line" ]; then
    bad "fish integration: the e05 line is below 'ghostty_exit', which runs 'exit 0' — it will never execute"
  fi
fi

# Sparkle, and the rpath that lets the binary find it. Signing verifies
# the framework is sealed, not that anything can load it: the release
# that shipped without this died on launch with 'Library not loaded'.
exists "Sparkle" "$C/Frameworks/Sparkle.framework"
if [ -x "$C/MacOS/e05" ]; then
  otool -l "$C/MacOS/e05" | grep -q '@executable_path/../Frameworks' \
    || bad "app binary has no @executable_path/../Frameworks rpath; Sparkle will not load"
fi

if [ "$fail" -eq 0 ]; then
  echo "verify_bundle: ${APP##*/} looks complete"
else
  echo "verify_bundle: FAILED" >&2
fi
exit "$fail"
