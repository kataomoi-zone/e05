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
  [ -n "$E05_BIN_DIR" ] || return
  # Strip any existing occurrence (mid / leading / trailing) so the
  # per-prompt run doesn't grow PATH, then prepend.
  local p=":$PATH:"
  p="${p//:$E05_BIN_DIR:/:}"
  p="${p#:}"
  p="${p%:}"
  PATH="$E05_BIN_DIR${p:+:$p}"
  export PATH
}

# Prepend to PROMPT_COMMAND, guarding against a double-add when the
# integration is sourced more than once in a session.
case ";${PROMPT_COMMAND};" in
  *";_e05_fix_path;"*) ;;
  *) PROMPT_COMMAND="_e05_fix_path${PROMPT_COMMAND:+;${PROMPT_COMMAND}}" ;;
esac
