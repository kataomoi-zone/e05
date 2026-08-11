# e05 PATH integration for fish shells spawned in e05's terminal panes.
#
# Keeps e05's bundled bin dir ahead of the system directories on PATH
# so the `open` shim (Resources/bin/open) shadows /usr/bin/open. Run as
# a fish_prompt event handler: it fires before each prompt, i.e. AFTER
# fish has built its own path list from /etc/paths and /etc/paths.d.
# Re-prepending here wins regardless of that ordering, and the exported
# PATH is inherited by child processes.
#
# Standalone e05 script under e05's own MIT license (see ../../LICENSE).
# Unlike the zsh and bash snippets there is no GPL question here: only
# those two of ghostty's integrations are Kitty-derived and GPLv3, and
# ghostty's fish integration is its own MIT code, so the `source` line
# injected into it carries no new obligation. The file is kept separate
# for symmetry with the other two.

function _e05_fix_path --on-event fish_prompt
    # The caller gates on E05_BIN_DIR too, but only once at source time;
    # this runs before every prompt. An empty value is the case that
    # matters: fish writes it into the exported PATH as a literal `.`,
    # the current directory. An unset one expands to no element at all,
    # so unlike zsh and bash there is nothing here for `nounset` to trip
    # over and no `:-` equivalent to write.
    test -n "$E05_BIN_DIR"; or return

    # Drop any existing entry first so repeated prompts don't grow PATH,
    # then prepend. Compared with `test`, not `string match`, whose
    # patterns are globs: a bundle path holding `*` would otherwise match
    # unrelated entries and drop them silently. Narrower than the trap in
    # the bash snippet — `[` has never been a fish glob and `?` stopped
    # being one in fish 4, so `*` is the whole of it here.
    set -l kept
    for entry in $PATH
        test "$entry" = "$E05_BIN_DIR"; or set -a kept $entry
    end
    set -gx PATH $E05_BIN_DIR $kept
end

# Replay the scrollback e05 captured for this pane at quit.
#
# libghostty has no API to write into a surface's screen, so the only
# way text reaches it is the child process's stdout — the shell prints
# the saved history itself. This runs at source time rather than from a
# prompt handler so the output lands before the first prompt, and the
# file is removed immediately so a later shell in the same pane cannot
# replay it a second time.
if test -n "$E05_RESTORE_SCROLLBACK_FILE"
    set -l restore_file $E05_RESTORE_SCROLLBACK_FILE
    # Erase before printing: a shell spawned from this one (tmux, a
    # nested login shell) would otherwise inherit the variable and try
    # again. `set -e` on an exported variable removes it from the
    # environment children see, not just from this shell.
    set -e E05_RESTORE_SCROLLBACK_FILE
    if test -r "$restore_file"
        # The file already ends with the timestamped rule that separates
        # restored history from this session — e05 appends it at capture
        # time so the stamp reflects when the history was taken.
        # `command` so a user-defined `cat` or `rm` cannot intercept it.
        command cat -- "$restore_file" 2>/dev/null
        command rm -f -- "$restore_file" 2>/dev/null
    end
end
