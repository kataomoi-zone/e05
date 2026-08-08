// libghostty patch for e05 — read the primary screen regardless of
// which screen is active. Companion to ghostty-command-text.snippet.zig;
// both land in the same patch file because they share an insertion
// region (applying them as separate patches would fight over line
// numbers).
//
// TWO files, same as the other snippet: ghostty.h is hand-written, so
// the Zig export alone creates the symbol but not the C declaration.
//
// On the ghostty checkout at the pinned commit (GHOSTTY_VERSION):
//
// (1) src/apprt/embedded.zig — paste the export below into
//     `pub const CAPI = struct { ... }`, after the
//     `ghostty_surface_command_text` export the other snippet adds.
//
// (2) include/ghostty.h — the declaration next to the other e05 line:
//
//       GHOSTTY_API bool ghostty_surface_read_primary_text(ghostty_surface_t, ghostty_selection_s, ghostty_text_s*);
//
// Then capture both e05 exports into one patch and rebuild GhosttyKit:
//
//   cd ~/ghq/github.com/ghostty-org/ghostty
//   git diff src/apprt/embedded.zig include/ghostty.h > <e05>/patches/ghostty-command-text.patch
//   /opt/homebrew/opt/zig@0.15/bin/zig build -Doptimize=ReleaseFast \
//     -Dapp-runtime=none -Demit-xcframework=true \
//     -Dxcframework-target=native -Demit-exe=false -Dsentry=false
//   cp -R macos/GhosttyKit.xcframework <e05>/
//
// Re-verify on a ghostty bump: ScreenSet.get / Screen.selectionString /
// Selection.core are not C-stable APIs.

    /// Read the primary screen in full, scrollback included, whichever
    /// screen is currently active.
    ///
    /// `ghostty_surface_read_text` resolves against `screens.active`,
    /// and a full-screen TUI (vim, less, htop) makes that the alternate
    /// screen. The alternate screen holds no scrollback, so a capture
    /// taken while one is running returns a screenful of TUI and drops
    /// the session's actual history. e05 captures scrollback at quit,
    /// which is exactly when an editor is likely to be open.
    ///
    /// The selection is resolved against the primary screen, so pass
    /// SCREEN/TOP_LEFT .. SCREEN/BOTTOM_RIGHT to mean "all of it". The
    /// viewport fields of the result are left unset (-1 / 0): they
    /// describe where text sits on the *active* screen, which is not
    /// what was read. Free with ghostty_surface_free_text.
    /// e05 patch (not upstream).
    export fn ghostty_surface_read_primary_text(
        surface: *Surface,
        sel: Selection,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const screen = core_surface.renderer_state.terminal.screens.get(
            .primary,
        ) orelse return false;

        const core_sel = sel.core(screen) orelse return false;

        // selectionString rather than dumpTextLocked: that helper reads
        // screens.active for both the text and the viewport metadata —
        // the very thing being avoided here — and the pixel/offset
        // fields it computes go unused by a capture.
        const text = screen.selectionString(global.alloc, .{
            .sel = core_sel,
            .trim = false,
        }) catch |err| {
            log.warn("error reading primary text err={}", .{err});
            return false;
        };

        result.* = .{
            .tl_px_x = -1,
            .tl_px_y = -1,
            .offset_start = 0,
            .offset_len = 0,
            .text = text.ptr,
            .text_len = text.len,
        };

        return true;
    }
