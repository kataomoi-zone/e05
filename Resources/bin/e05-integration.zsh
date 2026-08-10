# e05 PATH integration for zsh shells spawned in e05's terminal panes.
#
# Keeps e05's bundled bin dir ahead of the system directories on PATH
# so the `open` shim (Resources/bin/open) shadows /usr/bin/open. Run as
# a precmd hook: it fires before each prompt, i.e. AFTER the login
# shell's /etc/zprofile path_helper has rebuilt PATH with the system
# dirs first. Re-prepending here wins regardless of that reordering,
# and the exported PATH is inherited by child processes and scripts.
#
# Standalone e05 script: it defines its own function and is merely
# `source`d by the bundled ghostty shell-integration, deriving nothing
# from it. Covered by e05's own MIT license (see ../../LICENSE), kept
# separate so e05 ships no GPL code of its own — only the one-line
# `source` appended into the GPLv3 integration stays under GPL.

_e05_fix_path() {
  # The caller gates on E05_BIN_DIR too, but only once at source time;
  # this runs before every prompt, and an empty value would prepend an
  # empty `path` entry — which is the current directory. `:-` so the
  # check survives `nounset` instead of tripping over the state it guards.
  [[ -n "${E05_BIN_DIR:-}" ]] || return
  # Drop any existing entry first so repeated prompts don't grow PATH,
  # then prepend. The `path` array stays synced to the exported PATH.
  path=("$E05_BIN_DIR" ${path:#$E05_BIN_DIR})
}

# add-zsh-hook manages the precmd_functions array safely (dedup +
# ordering), avoiding races with ghostty's own precmd manipulation.
autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _e05_fix_path

# Replay the scrollback e05 captured for this pane at quit.
#
# libghostty has no API to write into a surface's screen, so the only
# way text reaches it is the child process's stdout — the shell prints
# the saved history itself. This runs at source time rather than from a
# hook so the output lands before the first prompt, and the file is
# removed immediately so a later shell in the same pane cannot replay it
# a second time.
_e05_restore_scrollback() {
  # NOT named `path`: that is tied to `PATH` in zsh as its array form, so
  # assigning to it splits the value on the colons and spaces of a real
  # pathname — and corrupts PATH on the way past.
  local restore_file="${E05_RESTORE_SCROLLBACK_FILE:-}"
  [[ -n "$restore_file" ]] || return 0
  # Unset before printing: a shell spawned from this one (tmux, a nested
  # login shell) would otherwise inherit the variable and try again.
  unset E05_RESTORE_SCROLLBACK_FILE
  [[ -r "$restore_file" ]] || return 0
  # The file already ends with the timestamped rule that separates
  # restored history from this session — e05 appends it at capture time
  # so the stamp reflects when the history was taken.
  command cat -- "$restore_file" 2>/dev/null
  command rm -f -- "$restore_file" 2>/dev/null
}
_e05_restore_scrollback
# One-shot: nothing calls it again, so keep it out of the user's namespace.
unset -f _e05_restore_scrollback
