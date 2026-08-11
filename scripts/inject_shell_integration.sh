#!/usr/bin/env bash
# Point ghostty's bundled shell integration at e05's own snippets.
#
# Usage: inject_shell_integration.sh <Contents-dir>
#
# Split out of build_app.sh so the test suite can run the real injection
# against a copy of the real files. It used to be inline, and the fish
# case shipped broken: the line was appended to a file whose last
# statement is `ghostty_exit`, and `exit` in a sourced fish file stops
# the rest of that file. Nothing noticed, because the tests sourced the
# snippets directly and never went through this step.
#
# Applied to the bundle copy only — the repo's vendored integration stays
# pristine so a ghostty version bump's rsync diff is clean, and this
# re-runs every build so the bump cannot silently drop it. The
# integration is Kitty-derived GPLv3; only the injected `source` line
# stays under GPL, since the snippets it loads are standalone e05 scripts
# (MIT). Each injection is idempotent: a second run finds its own marker
# and does nothing.
set -euo pipefail

CONTENTS="${1:?usage: inject_shell_integration.sh <Contents-dir>}"
INTEG_DIR="$CONTENTS/Resources/ghostty/shell-integration"

# require <path> — vendored files, so a miss means a ghostty bump moved
# them and the integration would otherwise vanish without a failure.
require() {
  [ -f "$1" ] || {
    echo "inject_shell_integration.sh: $1 not found — did a ghostty bump move it?" >&2
    exit 1
  }
}

ZSH_INTEG="$INTEG_DIR/zsh/ghostty-integration"
require "$ZSH_INTEG"
if ! grep -q 'e05-integration.zsh' "$ZSH_INTEG"; then
  cat >> "$ZSH_INTEG" <<'EOF'

# e05: keep the bundled bin dir ahead on PATH so the `open` shim wins.
# Injected at bundle time; active only inside e05 (E05_BIN_DIR gate).
# `:-` so the gate skips under `nounset` instead of erroring out.
[[ -n "${E05_BIN_DIR:-}" ]] && builtin source "$E05_BIN_DIR/e05-integration.zsh"
EOF
fi

BASH_INTEG="$INTEG_DIR/bash/ghostty.bash"
require "$BASH_INTEG"
if ! grep -q 'e05-integration.bash' "$BASH_INTEG"; then
  cat >> "$BASH_INTEG" <<'EOF'

# e05: keep the bundled bin dir ahead on PATH so the `open` shim wins.
# Injected at bundle time; active only inside e05 (E05_BIN_DIR gate).
# `:-` so the gate skips under `set -u` instead of erroring out.
[ -n "${E05_BIN_DIR:-}" ] && . "$E05_BIN_DIR/e05-integration.bash"
EOF
fi

# fish is the one that cannot be appended to. The file's last statement
# is `ghostty_exit`, whose body ends in `exit 0`, and `exit` inside a
# sourced fish file stops that file — anything after it is unreachable.
# Inserting just above it also keeps the non-interactive early-out at the
# top of the file working, so `fish -c` still produces no replay output.
FISH_INTEG="$INTEG_DIR/fish/vendor_conf.d/ghostty-shell-integration.fish"
require "$FISH_INTEG"
if ! grep -q 'e05-integration.fish' "$FISH_INTEG"; then
  grep -q '^ghostty_exit$' "$FISH_INTEG" || {
    echo "inject_shell_integration.sh: no trailing 'ghostty_exit' in $FISH_INTEG" >&2
    echo "  the insertion point is gone; re-check the file before shipping fish support" >&2
    exit 1
  }
  # `\$` throughout the replacement: perl interpolates it otherwise, and
  # an empty expansion here is exactly the kind of silent no-op this
  # script exists to prevent.
  perl -0777 -pi -e 's/\nghostty_exit\n\z/\n# e05: keep the bundled bin dir ahead on PATH so the `open` shim wins.\n# Injected at bundle time; active only inside e05 (E05_BIN_DIR gate).\n# Above ghostty_exit, which ends this file with `exit 0`.\ntest -n "\$E05_BIN_DIR"; and source "\$E05_BIN_DIR\/e05-integration.fish"\n\nghostty_exit\n/' "$FISH_INTEG"
  grep -q 'source "\$E05_BIN_DIR/e05-integration.fish"' "$FISH_INTEG" || {
    echo "inject_shell_integration.sh: fish line landed without its variable" >&2
    exit 1
  }
  grep -q 'e05-integration.fish' "$FISH_INTEG" || {
    echo "inject_shell_integration.sh: fish injection did not apply to $FISH_INTEG" >&2
    exit 1
  }
fi
