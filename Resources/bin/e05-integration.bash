# e05 PATH integration for bash shells spawned in e05's terminal panes.
#
# Keeps e05's bundled bin dir ahead of the system directories on PATH
# so the `open` shim (Resources/bin/open) shadows /usr/bin/open. Run
# from PROMPT_COMMAND: it fires before each prompt, i.e. AFTER the
# login shell's /etc/profile path_helper has rebuilt PATH with the
# system dirs first. Re-prepending here wins regardless of that
# reordering, and the exported PATH is inherited by child processes.
#
# Standalone e05 script: it defines its own function and is merely
# `source`d by the bundled ghostty shell-integration, deriving nothing
# from it. Covered by e05's own MIT license (see ../../LICENSE), kept
# separate so e05 ships no GPL code of its own — only the one-line
# `source` appended into the GPLv3 integration stays under GPL.

_e05_fix_path() {
  # The caller gates on E05_BIN_DIR too, but only once at source time;
  # this runs before every prompt, and an empty value would prepend an
  # empty PATH entry — which is the current directory. `:-` so the check
  # survives `set -u` instead of tripping over the state it guards.
  [ -n "${E05_BIN_DIR:-}" ] || return
  # Strip any existing occurrence (mid / leading / trailing) so the
  # per-prompt run doesn't grow PATH, then prepend. The pattern is
  # quoted: bash treats the expansion as a glob otherwise, so a bundle
  # path holding `[`, `*` or `?` would match nothing (PATH then grows by
  # one entry every prompt) while matching unrelated entries that happen
  # to fit the pattern (those get dropped).
  local p=":$PATH:"
  p="${p//":$E05_BIN_DIR:"/:}"
  p="${p#:}"
  p="${p%:}"
  PATH="$E05_BIN_DIR${p:+:$p}"
  export PATH
}

# Prepend to PROMPT_COMMAND, guarding against a double-add when the
# integration is sourced more than once in a session. `:-` because an
# unset PROMPT_COMMAND is the normal state, and this file is sourced
# after the user's bashrc — so a `set -u` there would abort the case and
# leave the hook unregistered, silently disabling the PATH fix.
case ";${PROMPT_COMMAND:-};" in
  *";_e05_fix_path;"*) ;;
  *) PROMPT_COMMAND="_e05_fix_path${PROMPT_COMMAND:+;${PROMPT_COMMAND}}" ;;
esac

# Replay the scrollback e05 captured for this pane at quit.
#
# libghostty has no API to write into a surface's screen, so the only
# way text reaches it is the child process's stdout — the shell prints
# the saved history itself. This runs at source time rather than from
# PROMPT_COMMAND so the output lands before the first prompt, and the
# file is removed immediately so a later shell in the same pane cannot
# replay it a second time.
_e05_restore_scrollback() {
  # Matches the zsh snippet's name deliberately: `path` is tied to `PATH`
  # there as its array form, so assigning to it splits a real pathname on
  # its colons and spaces. Harmless in bash, but keeping the two the same
  # means the trap only has to be remembered once.
  local restore_file="${E05_RESTORE_SCROLLBACK_FILE:-}"
  [ -n "$restore_file" ] || return 0
  # Unset before printing: a shell spawned from this one (tmux, a nested
  # login shell) would otherwise inherit the variable and try again.
  unset E05_RESTORE_SCROLLBACK_FILE
  [ -r "$restore_file" ] || return 0
  # The file already ends with the timestamped rule that separates
  # restored history from this session — e05 appends it at capture time
  # so the stamp reflects when the history was taken.
  command cat -- "$restore_file" 2>/dev/null
  command rm -f -- "$restore_file" 2>/dev/null
}
_e05_restore_scrollback
# One-shot: nothing calls it again, so keep it out of the user's namespace.
unset -f _e05_restore_scrollback
