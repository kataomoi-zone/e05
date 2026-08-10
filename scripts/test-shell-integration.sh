#!/usr/bin/env bash
# Behavioural tests for the shell-integration snippets under
# Resources/bin/e05-integration.{zsh,bash}.
#
# They are the one part of e05 no Swift test can reach, and every bug
# they have shipped was a shell behaviour that only appears when the code
# runs: a local named `path`, which zsh ties to PATH; an unset
# PROMPT_COMMAND under `set -u`; an unquoted substitution pattern read as
# a glob. All are asserted below.
#
# Each case runs in a pristine shell (`--noprofile --norc` / `zsh -f`) so
# the developer's own dotfiles cannot mask a failure, and prints exactly
# one line that is compared against the expected string.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
INTEG="$REPO/Resources/bin"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A directory name with a space: the shape that broke PATH once already.
HIST_DIR="$TMP/scroll back"
mkdir -p "$HIST_DIR"

pass=0
fail=0

# check <label> <expected> <actual>
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n         want: [%s]\n         got:  [%s]\n' "$1" "$2" "$3"
  fi
}

# run_<shell> <label> <expected> < body-on-stdin
# The body goes to a file rather than `-c` so quoting in the cases stays
# readable; $INTEG and $HIST_DIR reach it as exports. stderr is folded
# into the comparison, so a snippet that aborts partway fails the case
# rather than passing on a truncated result.
export INTEG HIST_DIR
run_bash() {
  cat > "$TMP/case.bash"
  check "bash: $1" "$2" "$("$BASH" --noprofile --norc "$TMP/case.bash" 2>&1)"
}
run_zsh() {
  cat > "$TMP/case.zsh"
  check "zsh:  $1" "$2" "$(zsh -f "$TMP/case.zsh" 2>&1)"
}

# Cases run under $BASH — the interpreter running this script — not the
# first `bash` on PATH. Otherwise `/bin/bash scripts/test-…` would look
# like it exercised the system bash while quietly handing every case to
# the Homebrew/nix 5.x ahead of it on PATH. The version is printed
# because developers and CI do not run the same one.
echo "== bash $BASH_VERSION =="

# `set -u` with PROMPT_COMMAND unset is the ordinary state for a bash
# user who hardens their bashrc; the snippet is sourced after it.
run_bash 'registers the hook under set -u' '_e05_fix_path' <<'EOF'
set -u
unset PROMPT_COMMAND
export E05_BIN_DIR=/opt/e05
. "$INTEG/e05-integration.bash"
printf %s "$PROMPT_COMMAND"
EOF

run_bash 'sourcing twice registers once' '_e05_fix_path' <<'EOF'
set -u
unset PROMPT_COMMAND
export E05_BIN_DIR=/opt/e05
. "$INTEG/e05-integration.bash"
. "$INTEG/e05-integration.bash"
printf %s "$PROMPT_COMMAND"
EOF

run_bash 'keeps an existing PROMPT_COMMAND, ours first' '_e05_fix_path;echo hi' <<'EOF'
set -u
export E05_BIN_DIR=/opt/e05
PROMPT_COMMAND='echo hi'
. "$INTEG/e05-integration.bash"
printf %s "$PROMPT_COMMAND"
EOF

run_bash 'prepends the bin dir' '/opt/e05:/usr/bin:/bin' <<'EOF'
export E05_BIN_DIR=/opt/e05
. "$INTEG/e05-integration.bash"
PATH=/usr/bin:/bin
_e05_fix_path
printf %s "$PATH"
EOF

# Runs before every prompt, so a non-idempotent version grows PATH
# without bound over a long session.
run_bash 'repeated calls do not grow PATH' '/opt/e05:/usr/bin:/bin' <<'EOF'
export E05_BIN_DIR=/opt/e05
. "$INTEG/e05-integration.bash"
PATH=/usr/bin:/bin
_e05_fix_path; _e05_fix_path; _e05_fix_path
printf %s "$PATH"
EOF

# path_helper in /etc/profile rebuilds PATH with the system dirs first;
# the entry must move to the front, not appear twice.
run_bash 'moves an existing entry to the front' '/opt/e05:/usr/bin:/bin' <<'EOF'
export E05_BIN_DIR=/opt/e05
. "$INTEG/e05-integration.bash"
PATH=/usr/bin:/opt/e05:/bin
_e05_fix_path
printf %s "$PATH"
EOF

# bash reads the right-hand side of ${var//pat/} as a glob. A bundle path
# holding `[`, `*` or `?` — an app renamed to "e05 [beta]", a checkout
# under a bracketed directory — then matches nothing, so the strip is a
# no-op and PATH gains an entry every single prompt.
run_bash 'a bin dir with glob metacharacters still dedups' '/opt/e05 [beta]/bin:/usr/bin:/bin' <<'EOF'
export E05_BIN_DIR='/opt/e05 [beta]/bin'
. "$INTEG/e05-integration.bash"
PATH=/usr/bin:/bin
_e05_fix_path; _e05_fix_path; _e05_fix_path
printf %s "$PATH"
EOF

# The same unquoted pattern is destructive in the other direction: it
# matches entries that merely fit it, and they are silently dropped.
run_bash 'a bin dir with a wildcard leaves other entries alone' '/opt/*/bin:/usr/bin:/opt/a/bin:/bin' <<'EOF'
export E05_BIN_DIR='/opt/*/bin'
. "$INTEG/e05-integration.bash"
PATH=/usr/bin:/opt/a/bin:/bin
_e05_fix_path
printf %s "$PATH"
EOF

# Without the guard an empty value prepends an empty PATH entry, which
# bash reads as the current directory.
run_bash 'guards an unset bin dir under set -u' '1|/usr/bin:/bin' <<'EOF'
set -u
export E05_BIN_DIR=/opt/e05
. "$INTEG/e05-integration.bash"
PATH=/usr/bin:/bin
unset E05_BIN_DIR
_e05_fix_path && rc=0 || rc=$?
printf '%s|%s' "$rc" "$PATH"
EOF

# Three properties in one pass, all of which the historical bug broke at
# once: the local was named `path`, which zsh ties to PATH as its array
# form, so the captured pathname — HIST_DIR contains a space — shredded
# PATH for the rest of the function and the `command cat` doing the
# replay could no longer be found. Silent, and it looked like an empty
# capture. Asserted in both shells so the two snippets cannot drift.
run_bash 'replays a spaced path, deletes it, leaves PATH intact' 'scrollback-content|gone|/usr/bin:/bin' <<'EOF'
set -u
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/hist.txt"
printf 'scrollback-content' > "$E05_RESTORE_SCROLLBACK_FILE"
file="$E05_RESTORE_SCROLLBACK_FILE"
PATH=/usr/bin:/bin
. "$INTEG/e05-integration.bash"
printf '|%s|%s' "$([ -e "$file" ] && echo still-there || echo gone)" "$PATH"
EOF

# A shell spawned from this one (tmux, a nested login shell) would
# otherwise inherit the variable and replay the same history again.
run_bash 'unsets the variable so a nested shell cannot replay' '<unset>' <<'EOF'
set -u
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/hist.txt"
: > "$E05_RESTORE_SCROLLBACK_FILE"
. "$INTEG/e05-integration.bash"
printf %s "${E05_RESTORE_SCROLLBACK_FILE:-<unset>}"
EOF

run_bash 'stays quiet when the capture is missing' 'quiet' <<'EOF'
set -u
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/absent.txt"
. "$INTEG/e05-integration.bash"
printf quiet
EOF

run_bash 'stays quiet with no capture configured' 'quiet' <<'EOF'
set -u
unset E05_RESTORE_SCROLLBACK_FILE
export E05_BIN_DIR=/opt/e05
. "$INTEG/e05-integration.bash"
printf quiet
EOF

echo "== zsh $(zsh -c 'echo $ZSH_VERSION') =="

run_zsh 'registers the precmd hook under nounset' 'yes' <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
[[ " ${precmd_functions[*]} " == *" _e05_fix_path "* ]] && print -n yes || print -n no
EOF

run_zsh 'sourcing twice registers once' '1' <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
source "$INTEG/e05-integration.zsh"
print -n ${(M)#precmd_functions:#_e05_fix_path}
EOF

# `autoload` defers, so it reports success even when the function cannot
# be found; only the call fails. A user whose fpath is broken must not
# silently lose the PATH fix.
run_zsh 'registers by hand when add-zsh-hook is unavailable' '_e05_fix_path' <<'EOF'
setopt nounset
fpath=()
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
print -n "${precmd_functions[*]}"
EOF

run_zsh 'prepends the bin dir' '/opt/e05:/usr/bin:/bin' <<'EOF'
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
PATH=/usr/bin:/bin
_e05_fix_path
print -rn -- "$PATH"
EOF

run_zsh 'repeated calls do not grow PATH' '/opt/e05:/usr/bin:/bin' <<'EOF'
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
PATH=/usr/bin:/bin
_e05_fix_path; _e05_fix_path; _e05_fix_path
print -rn -- "$PATH"
EOF

run_zsh 'moves an existing entry to the front' '/opt/e05:/usr/bin:/bin' <<'EOF'
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
PATH=/usr/bin:/opt/e05:/bin
_e05_fix_path
print -rn -- "$PATH"
EOF

run_zsh 'a bin dir with glob metacharacters still dedups' '/opt/e05 [beta]/bin:/usr/bin:/bin' <<'EOF'
export E05_BIN_DIR='/opt/e05 [beta]/bin'
source "$INTEG/e05-integration.zsh"
PATH=/usr/bin:/bin
_e05_fix_path; _e05_fix_path; _e05_fix_path
print -rn -- "$PATH"
EOF

# Both options are things a user can set in their own zshrc, and the
# snippet is sourced afterwards. Unquoted, sh_word_split splits a PATH
# entry containing a space and globsubst turns the bundle path into a
# pattern that eats unrelated entries.
run_zsh 'sh_word_split keeps a spaced PATH entry whole' '/opt/e05:/usr/bin:/my dir/bin:/bin' <<'EOF'
setopt sh_word_split
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
PATH="/usr/bin:/my dir/bin:/bin"
_e05_fix_path
print -rn -- "$PATH"
EOF

run_zsh 'globsubst leaves other entries alone' '/opt/e*05:/usr/bin:/opt/eXX05:/bin' <<'EOF'
setopt globsubst
export E05_BIN_DIR='/opt/e*05'
source "$INTEG/e05-integration.zsh"
PATH="/usr/bin:/opt/eXX05:/bin"
_e05_fix_path
print -rn -- "$PATH"
EOF

run_zsh 'guards an unset bin dir under nounset' '1|/usr/bin:/bin' <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
PATH=/usr/bin:/bin
unset E05_BIN_DIR
_e05_fix_path && rc=0 || rc=$?
printf '%s|%s' "$rc" "$PATH"
EOF

run_zsh 'replays a spaced path, deletes it, leaves PATH intact' 'scrollback-content|gone|/usr/bin:/bin' <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/hist.txt"
printf 'scrollback-content' > "$E05_RESTORE_SCROLLBACK_FILE"
file="$E05_RESTORE_SCROLLBACK_FILE"
PATH=/usr/bin:/bin
source "$INTEG/e05-integration.zsh"
printf '|%s|%s' "$([[ -e "$file" ]] && print still-there || print gone)" "$PATH"
EOF

run_zsh 'unsets the variable so a nested shell cannot replay' '<unset>' <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/hist.txt"
: > "$E05_RESTORE_SCROLLBACK_FILE"
source "$INTEG/e05-integration.zsh"
print -n "${E05_RESTORE_SCROLLBACK_FILE:-<unset>}"
EOF

run_zsh 'stays quiet when the capture is missing' 'quiet' <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/absent.txt"
source "$INTEG/e05-integration.zsh"
print -n quiet
EOF

run_zsh 'stays quiet with no capture configured' 'quiet' <<'EOF'
setopt nounset
unset E05_RESTORE_SCROLLBACK_FILE
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
print -n quiet
EOF

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
