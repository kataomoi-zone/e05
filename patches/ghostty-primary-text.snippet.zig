// libghostty patch for e05 — read the primary screen regardless of
// which screen is active, plain or styled. Companion to
// ghostty-command-text.snippet.zig; both land in the same patch file
// because they share an insertion region (applying them as separate
// patches would fight over line numbers).
//
// TWO files, same as the other snippet: ghostty.h is hand-written, so
// the Zig export alone creates the symbol but not the C declaration.
//
// On the ghostty checkout at the pinned commit (GHOSTTY_VERSION):
//
// (1) src/apprt/embedded.zig — paste the export below into
//     `pub const CAPI = struct { ... }`, after the
//     `ghostty_surface_command_text` export the other snippet adds.
//     (If you applied the earlier plain-only version, replace it
//     wholesale: the signature gained the `styled` argument.)
//
// (2) include/ghostty.h — the declaration next to the other e05 line:
//
//       GHOSTTY_API bool ghostty_surface_read_primary_text(ghostty_surface_t, ghostty_selection_s, bool, ghostty_text_s*);
//
// Then capture both e05 exports into the one patch, from the ghostty
// checkout:
//
//   git diff src/apprt/embedded.zig include/ghostty.h > <e05>/patches/ghostty-command-text.patch
//
// and rebuild GhosttyKit with `scripts/bump_ghostty.sh`, which applies
// patches/, builds, and vendors the xcframework in.
//
// Re-verify on a ghostty bump, none of it C-stable: ScreenSet.get,
// Selection.core, formatter.ScreenFormatter and its Options — and
// ScreenFormatter.Extra's default of `.none`, which this relies on
// without saying so. That default is what keeps OSC 8, cursor moves and
// charset designations out of a capture; a capture is replayed by
// `cat`ting it into a live pane, so anything beyond SGR that got in
// would be executed there.

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
    /// With `styled`, the text carries SGR sequences and rows end with
    /// CRLF; without it, the result matches `screen.selectionString`.
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
        styled: bool,
        result: *Text,
    ) bool {
        const core_surface = &surface.core_surface;
        core_surface.renderer_state.mutex.lock();
        defer core_surface.renderer_state.mutex.unlock();

        const screen = core_surface.renderer_state.terminal.screens.get(
            .primary,
        ) orelse return false;

        const core_sel = sel.core(screen) orelse return false;

        // The formatter directly rather than screen.selectionString:
        // that helper is the same call with `.emit` pinned to `.plain`.
        //
        // palette, background and foreground stay null, which is what
        // makes a styled read safe to replay. A null palette emits
        // colors as palette *indexes* rather than resolved RGB, so a
        // restored capture follows whatever theme is live when it is
        // replayed; null background/foreground suppress the OSC 10/11
        // pair that would otherwise carry the capture-time theme along
        // and override the live one. (write_screen_file passes all
        // three, which is why that route bakes the old theme in.)
        var aw: std.Io.Writer.Allocating = .init(global.alloc);
        defer aw.deinit();

        var formatter: terminal.formatter.ScreenFormatter = .init(screen, .{
            .emit = if (styled) .vt else .plain,
            .unwrap = true,
            .trim = false,
        });
        formatter.content = .{ .selection = core_sel };
        formatter.format(&aw.writer) catch |err| {
            log.warn("error formatting primary text err={}", .{err});
            return false;
        };

        // Sentinel-terminated because Text.deinit frees it as [:0].
        const text = aw.toOwnedSliceSentinel(0) catch |err| {
            log.warn("error allocating primary text err={}", .{err});
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
