// libghostty patch for e05 — command-output copy (OSC 133 / Bucket B).
// TWO files: ghostty.h is hand-written (not generated), so the Zig export
// alone makes the symbol but not the C declaration e05 calls against.
//
// On the ghostty checkout at the pinned commit (GHOSTTY_VERSION = 5659cef41):
//
// (1) src/apprt/embedded.zig — paste / REPLACE the `ghostty_surface_command_text`
//     export below into `pub const CAPI = struct { ... }`, directly AFTER
//     the `ghostty_surface_free_text` export, before `ghostty_surface_refresh`.
//     (If you applied the earlier 2-mode version, replace it wholesale.)
//
// (2) include/ghostty.h — the declaration right AFTER the existing
//     `ghostty_surface_free_text` line (~1164). The 4th arg is the mode
//     (uint8_t), not a bool:
//
//       GHOSTTY_API bool ghostty_surface_command_text(ghostty_surface_t, ghostty_point_s, bool, uint8_t, ghostty_text_s*);
//
// Then capture the canonical patch (both files) and rebuild GhosttyKit:
//
//   cd ~/ghq/github.com/ghostty-org/ghostty
//   git diff src/apprt/embedded.zig include/ghostty.h > <e05>/patches/ghostty-command-text.patch
//   /opt/homebrew/opt/zig@0.15/bin/zig build -Doptimize=ReleaseFast \
//     -Dapp-runtime=none -Demit-xcframework=true \
//     -Dxcframework-target=native -Demit-exe=false -Dsentry=false
//   cp -R macos/GhosttyKit.xcframework <e05>/
//
// (codesign "resource fork ... not allowed" → run `xattr -cr macos zig-out`
// first.) Re-verify on a ghostty bump: highlightSemanticContent /
// promptIterator are not C-stable APIs.

    /// Read the text of a shell command identified by OSC 133 semantic
    /// prompt marks. When `use_last` is true, `point` is ignored and the
    /// most recently completed command — the one above the cursor's prompt
    /// — is used; otherwise the command whose region contains `point` is
    /// used. `mode` selects what to read: 0 = output only, 1 = the command's
    /// input line(s) plus its output, 2 = the command's input line(s) only
    /// (the typed command, no prompt decoration, no output). Requires shell
    /// integration; returns false when no matching command exists. Free the
    /// result with ghostty_surface_free_text. e05 patch (not upstream).
    export fn ghostty_surface_command_text(
        surface: *Surface,
        point: Point,
        use_last: bool,
        mode: u8,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const screen = core_surface.renderer_state.terminal.screens.active;

        // Resolve the prompt row of the target command.
        const prompt_pin = pin: {
            if (use_last) {
                // The cursor sits on the current prompt; the command above
                // it is the most recently completed one.
                const cursor_pin = screen.cursor.page_pin.*;
                var cur_it = cursor_pin.promptIterator(.left_up, null);
                const current = cur_it.next() orelse return false;
                const above = current.up(1) orelse return false;
                var prev_it = above.promptIterator(.left_up, null);
                break :pin prev_it.next() orelse return false;
            } else {
                const at = point.pin(screen) orelse return false;
                var it = at.promptIterator(.left_up, null);
                break :pin it.next() orelse return false;
            }
        };

        // Build the selection. highlightSemanticContent already trims
        // trailing blank cells.
        const core_sel: terminal.Selection = sel: {
            switch (mode) {
                // The typed command only (no prompt decoration, no output).
                2 => {
                    const command = screen.pages.highlightSemanticContent(
                        prompt_pin,
                        .input,
                    ) orelse return false;
                    break :sel .{
                        .bounds = .{ .untracked = .{ .start = command.start, .end = command.end } },
                        .rectangle = false,
                    };
                },
                // The command's input line(s) through the end of its output.
                1 => {
                    const cmd = screen.pages.highlightSemanticContent(
                        prompt_pin,
                        .prompt,
                    ) orelse return false;
                    const output = screen.pages.highlightSemanticContent(prompt_pin, .output);
                    break :sel .{
                        .bounds = .{ .untracked = .{
                            .start = cmd.start,
                            .end = if (output) |o| o.end else cmd.end,
                        } },
                        .rectangle = false,
                    };
                },
                // Output only.
                else => {
                    const o = screen.pages.highlightSemanticContent(
                        prompt_pin,
                        .output,
                    ) orelse return false;
                    break :sel .{
                        .bounds = .{ .untracked = .{ .start = o.start, .end = o.end } },
                        .rectangle = false,
                    };
                },
            }
        };

        return readTextLocked(surface, core_sel, result);
    }
