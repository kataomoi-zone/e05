#!/usr/bin/env bash
# Behavioural tests for the shell-integration snippets under
# Resources/bin/e05-integration.{zsh,bash,fish}.
#
# No Swift test can reach them, and every bug they have shipped was a
# shell behaviour that only appears when the code runs: a local named
# `path`, which zsh ties to PATH; an unset PROMPT_COMMAND under `set -u`;
# an unquoted substitution pattern read as a glob. All are asserted
# below. (`Resources/bin/open` is shell too, and still uncovered.)
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

# Eleven lines, so a replay that truncates is distinguishable from one
# that does not — `head` defaults to ten, and a one-line fixture cannot
# tell the two apart. No trailing newline: a real capture ends on the old
# prompt line. Written with `%b` so the cases and the expected string
# come from this one definition.
REPLAY_FIXTURE='l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11'
REPLAY_LINES=$(printf '%b' "$REPLAY_FIXTURE")
export REPLAY_FIXTURE

pass=0
fail=0
skipped_shells=""

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
run_fish() {
  cat > "$TMP/case.fish"
  check "fish: $1" "$2" "$(fish --no-config "$TMP/case.fish" 2>&1)"
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

# bash reads the right-hand side of ${var//pat/} as a glob. A `[` opens
# a bracket expression, which matches nothing here — an app renamed to
# "e05 [beta]", a checkout under a bracketed directory — so the strip is
# a no-op and PATH gains an entry every single prompt.
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
run_bash 'replays a spaced path in full, deletes it, leaves PATH intact' "$REPLAY_LINES|gone|/usr/bin:/bin" <<'EOF'
set -u
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/hist.txt"
printf '%b' "$REPLAY_FIXTURE" > "$E05_RESTORE_SCROLLBACK_FILE"
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

# The unset has to happen before the readability test, not after it: a
# missing capture must still clear the variable, or a nested shell
# inherits a path to a file that is never going to appear. `-` rather
# than `:-` so an empty value is not reported as unset.
run_bash 'clears the variable even when the capture is missing' 'quiet|<unset>' <<'EOF'
set -u
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/absent.txt"
. "$INTEG/e05-integration.bash"
printf 'quiet|%s' "${E05_RESTORE_SCROLLBACK_FILE-<unset>}"
EOF

# `command` in front of cat and rm: a user with their own `cat` — a
# pager wrapper, a colouriser — must not get to see the capture, and one
# with their own `rm` must not keep it on disk.
run_bash 'a user cat function cannot intercept the replay' 'l1|gone' <<'EOF'
set -u
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/hijack.txt"
printf l1 > "$E05_RESTORE_SCROLLBACK_FILE"
file="$E05_RESTORE_SCROLLBACK_FILE"
cat() { printf intercepted; }
rm() { :; }
. "$INTEG/e05-integration.bash"
printf '|%s' "$([ -e "$file" ] && echo still-there || echo gone)"
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

run_zsh 'replays a spaced path in full, deletes it, leaves PATH intact' "$REPLAY_LINES|gone|/usr/bin:/bin" <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/hist.txt"
printf '%b' "$REPLAY_FIXTURE" > "$E05_RESTORE_SCROLLBACK_FILE"
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

run_zsh 'clears the variable even when the capture is missing' 'quiet|<unset>' <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/absent.txt"
source "$INTEG/e05-integration.zsh"
printf 'quiet|%s' "${E05_RESTORE_SCROLLBACK_FILE-<unset>}"
EOF

run_zsh 'a user cat function cannot intercept the replay' 'l1|gone' <<'EOF'
setopt nounset
export E05_BIN_DIR=/opt/e05
export E05_RESTORE_SCROLLBACK_FILE="$HIST_DIR/hijack.txt"
printf l1 > "$E05_RESTORE_SCROLLBACK_FILE"
file="$E05_RESTORE_SCROLLBACK_FILE"
cat() { printf intercepted; }
rm() { :; }
source "$INTEG/e05-integration.zsh"
printf '|%s' "$([[ -e "$file" ]] && print still-there || print gone)"
EOF

run_zsh 'stays quiet with no capture configured' 'quiet' <<'EOF'
setopt nounset
unset E05_RESTORE_SCROLLBACK_FILE
export E05_BIN_DIR=/opt/e05
source "$INTEG/e05-integration.zsh"
print -n quiet
EOF

# fish is not on a stock macOS, so a developer without it gets a skip
# rather than a failure — reported in the summary, never as a pass. CI
# installs it, so CI never takes this branch.
if ! command -v fish > /dev/null; then
  echo "== fish == SKIPPED, not installed (\`brew install fish\`, or \`nix shell nixpkgs#fish -c\`)"
  skipped_shells="fish"
else
  # shellcheck disable=SC2016  # $version is fish's, and fish expands it
  echo "== fish $(fish --no-config -c 'echo $version') =="

  # Emitting the event rather than looking the function up by name: what
  # matters is that it is wired to fish_prompt, not that it exists.
  run_fish 'runs on the prompt event' '/opt/e05:/usr/bin:/bin' <<'EOF'
set -gx E05_BIN_DIR /opt/e05
source "$INTEG/e05-integration.fish"
set -gx PATH /usr/bin /bin
emit fish_prompt
sh -c 'printf %s "$PATH"'
EOF

  run_fish 'prepends the bin dir' '/opt/e05:/usr/bin:/bin' <<'EOF'
set -gx E05_BIN_DIR /opt/e05
source "$INTEG/e05-integration.fish"
set -gx PATH /usr/bin /bin
_e05_fix_path
sh -c 'printf %s "$PATH"'
EOF

  run_fish 'repeated calls do not grow PATH' '/opt/e05:/usr/bin:/bin' <<'EOF'
set -gx E05_BIN_DIR /opt/e05
source "$INTEG/e05-integration.fish"
set -gx PATH /usr/bin /bin
_e05_fix_path
_e05_fix_path
_e05_fix_path
sh -c 'printf %s "$PATH"'
EOF

  run_fish 'moves an existing entry to the front' '/opt/e05:/usr/bin:/bin' <<'EOF'
set -gx E05_BIN_DIR /opt/e05
source "$INTEG/e05-integration.fish"
set -gx PATH /usr/bin /opt/e05 /bin
_e05_fix_path
sh -c 'printf %s "$PATH"'
EOF

  # Not a glob case, unlike its bash and zsh namesakes: `[` is literal to
  # fish, so `string match` would dedup this correctly too. What it does
  # cover is a bundle path with a space in it. The glob hazard in fish is
  # `*` alone, and the next case is the one that pins it.
  run_fish 'a bin dir with brackets and a space still dedups' '/opt/e05 [beta]/bin:/usr/bin:/bin' <<'EOF'
set -gx E05_BIN_DIR '/opt/e05 [beta]/bin'
source "$INTEG/e05-integration.fish"
set -gx PATH /usr/bin /bin
_e05_fix_path
_e05_fix_path
_e05_fix_path
sh -c 'printf %s "$PATH"'
EOF

  run_fish 'a bin dir with a wildcard leaves other entries alone' '/opt/*/bin:/usr/bin:/opt/a/bin:/bin' <<'EOF'
set -gx E05_BIN_DIR '/opt/*/bin'
source "$INTEG/e05-integration.fish"
set -gx PATH /usr/bin /opt/a/bin /bin
_e05_fix_path
sh -c 'printf %s "$PATH"'
EOF

  # An empty value is the one that bites in fish: it survives into the
  # exported PATH as a literal `.`. An unset one expands to nothing at
  # all and is harmless — both are asserted so the difference is on the
  # record rather than assumed.
  run_fish 'guards an empty or unset bin dir' '/usr/bin:/bin|/usr/bin:/bin' <<'EOF'
set -gx E05_BIN_DIR /opt/e05
source "$INTEG/e05-integration.fish"

set -gx PATH /usr/bin /bin
set -gx E05_BIN_DIR ''
_e05_fix_path
sh -c 'printf %s "$PATH"'

set -gx PATH /usr/bin /bin
set -e E05_BIN_DIR
_e05_fix_path
sh -c 'printf "|%s" "$PATH"'
EOF

  run_fish 'replays a spaced path in full, deletes it, leaves PATH intact' \
    "$REPLAY_LINES|gone|/usr/bin:/bin" <<'EOF'
set -gx E05_BIN_DIR /opt/e05
set -gx E05_RESTORE_SCROLLBACK_FILE "$HIST_DIR/hist.txt"
printf '%b' "$REPLAY_FIXTURE" > "$E05_RESTORE_SCROLLBACK_FILE"
set -l file $E05_RESTORE_SCROLLBACK_FILE
set -gx PATH /usr/bin /bin
source "$INTEG/e05-integration.fish"
if test -e "$file"
    printf '|still-there'
else
    printf '|gone'
end
sh -c 'printf "|%s" "$PATH"'
EOF

  run_fish 'unsets the variable so a nested shell cannot replay' '<unset>' <<'EOF'
set -gx E05_BIN_DIR /opt/e05
set -gx E05_RESTORE_SCROLLBACK_FILE "$HIST_DIR/hist.txt"
printf '' > "$E05_RESTORE_SCROLLBACK_FILE"
source "$INTEG/e05-integration.fish"
sh -c 'printf %s "${E05_RESTORE_SCROLLBACK_FILE-<unset>}"'
EOF

  run_fish 'clears the variable even when the capture is missing' 'quiet|<unset>' <<'EOF'
set -gx E05_BIN_DIR /opt/e05
set -gx E05_RESTORE_SCROLLBACK_FILE "$HIST_DIR/absent.txt"
source "$INTEG/e05-integration.fish"
printf quiet
sh -c 'printf "|%s" "${E05_RESTORE_SCROLLBACK_FILE-<unset>}"'
EOF

  run_fish 'a user cat function cannot intercept the replay' 'l1|gone' <<'EOF'
set -gx E05_BIN_DIR /opt/e05
set -gx E05_RESTORE_SCROLLBACK_FILE "$HIST_DIR/hijack.txt"
printf l1 > "$E05_RESTORE_SCROLLBACK_FILE"
set -l file $E05_RESTORE_SCROLLBACK_FILE
function cat
    printf intercepted
end
function rm
end
source "$INTEG/e05-integration.fish"
if test -e "$file"
    printf '|still-there'
else
    printf '|gone'
end
EOF

  run_fish 'stays quiet with no capture configured' 'quiet' <<'EOF'
set -e E05_RESTORE_SCROLLBACK_FILE
set -gx E05_BIN_DIR /opt/e05
source "$INTEG/e05-integration.fish"
printf quiet
EOF
fi

# --- the injection step ---
#
# Every case above sources a snippet directly, which is not how a shell
# ever gets it: `scripts/inject_shell_integration.sh` puts a line into
# ghostty's own integration file, and the shell reaches the snippet
# through that. Nothing checked the line was reachable until this
# section existed, and in fish it was not — the file ends in a call that
# runs `exit 0`, and `exit` in a sourced fish file stops the rest of it.
# The snippet tests were all green throughout.
echo "== injection =="

INJECTED="$TMP/Contents"
mkdir -p "$INJECTED/Resources/ghostty" "$INJECTED/Resources/bin"
cp -R "$REPO/Resources/ghostty/shell-integration" "$INJECTED/Resources/ghostty/"
cp "$INTEG"/e05-integration.* "$INJECTED/Resources/bin/"
GHOSTTY_INTEG="$INJECTED/Resources/ghostty/shell-integration"
INJECTED_BIN="$INJECTED/Resources/bin"
export INJECTED_BIN

if inject_out=$("$REPO/scripts/inject_shell_integration.sh" "$INJECTED" 2>&1); then
  check "inject: runs clean against the vendored files" "" "$inject_out"
else
  check "inject: runs clean against the vendored files" "" "FAILED: $inject_out"
fi

# Interactive shells here: both ghostty snippets return early when the
# shell is not interactive, which is the whole point of the line's
# placement. stdout only, because an interactive shell on a pipe warns
# about job control on stderr and that is not a failure.
check "inject: zsh reaches the e05 line" "_e05_fix_path" \
  "$(E05_BIN_DIR="$INJECTED_BIN" zsh -f -i -c \
    "source '$GHOSTTY_INTEG/zsh/ghostty-integration'; (( \$+functions[_e05_fix_path] )) && print -n _e05_fix_path" \
    2> /dev/null)"

check "inject: bash reaches the e05 line" "_e05_fix_path" \
  "$(E05_BIN_DIR="$INJECTED_BIN" "$BASH" --noprofile --norc -i -c \
    "source '$GHOSTTY_INTEG/bash/ghostty.bash'; declare -F _e05_fix_path > /dev/null && printf _e05_fix_path" \
    2> /dev/null)"

if [ -z "$skipped_shells" ]; then
  check "inject: fish reaches the e05 line" "_e05_fix_path" \
    "$(E05_BIN_DIR="$INJECTED_BIN" fish --no-config -i -c \
      "source '$GHOSTTY_INTEG/fish/vendor_conf.d/ghostty-shell-integration.fish'; functions -q _e05_fix_path; and printf _e05_fix_path" \
      2> /dev/null)"

  # The line sits above ghostty's own early-out for non-interactive
  # shells, so `fish -c` must neither print the capture nor eat it.
  printf 'HISTORY' > "$INJECTED/hist.txt"
  check "inject: a non-interactive fish replays nothing" "marker|still-there" \
    "$(E05_BIN_DIR="$INJECTED_BIN" E05_RESTORE_SCROLLBACK_FILE="$INJECTED/hist.txt" fish --no-config -c \
      "source '$GHOSTTY_INTEG/fish/vendor_conf.d/ghostty-shell-integration.fish'; printf marker" \
      2> /dev/null)|$([ -e "$INJECTED/hist.txt" ] && echo still-there || echo gone)"
fi

# Running it twice must not add a second line: build_app.sh re-runs it
# on every build.
"$REPO/scripts/inject_shell_integration.sh" "$INJECTED" > /dev/null 2>&1
check "inject: a second run adds nothing" "1 1 1" \
  "$(grep -c 'e05-integration.zsh' "$GHOSTTY_INTEG/zsh/ghostty-integration") \
$(grep -c 'e05-integration.bash' "$GHOSTTY_INTEG/bash/ghostty.bash") \
$(grep -c 'e05-integration.fish' "$GHOSTTY_INTEG/fish/vendor_conf.d/ghostty-shell-integration.fish")"

if [ -n "$skipped_shells" ]; then
  printf '\n%d passed, %d failed, SKIPPED: %s\n' "$pass" "$fail" "$skipped_shells"
else
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
fi
[ "$fail" -eq 0 ]
