# e05 PATH integration for zsh shells spawned in e05's terminal panes.
#
# Keeps e05's bundled bin dir ahead of the system directories on PATH
# so the `open` shim (Resources/bin/open) shadows /usr/bin/open. Run as
# a precmd hook: it fires before each prompt, i.e. AFTER the login
# shell's /etc/zprofile path_helper has rebuilt PATH with the system
# dirs first. Re-prepending here wins regardless of that reordering,
# and the exported PATH is inherited by child processes and scripts.
#
# Sourced from the bundled ghostty shell-integration (Kitty-derived,
# GPLv3), so this file is distributed under GPLv3 to match:
# This program is free software under the GNU General Public License
# version 3 or later, WITHOUT ANY WARRANTY. See
# <https://www.gnu.org/licenses/>.

_e05_fix_path() {
  [[ -n "$E05_BIN_DIR" ]] || return
  # Drop any existing entry first so repeated prompts don't grow PATH,
  # then prepend. The `path` array stays synced to the exported PATH.
  path=("$E05_BIN_DIR" ${path:#$E05_BIN_DIR})
}

# add-zsh-hook manages the precmd_functions array safely (dedup +
# ordering), avoiding races with ghostty's own precmd manipulation.
autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd _e05_fix_path
