import AppKit
import GhosttyKit

/// Manages the ghostty runtime lifecycle: init, config, app, tick.
@MainActor
public final class GhosttyApp {
    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    public var onSetTitle: ((ghostty_surface_t, String) -> Void)?

    public init() {
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        guard initResult == 0 else {
            NSLog("[e05] ghostty_init failed: \(initResult)")
            return
        }

        guard let cfg = ghostty_config_new() else {
            NSLog("[e05] ghostty_config_new failed")
            return
        }
        let configPath = NSString("~/.config/e05/config").expandingTildeInPath
        if FileManager.default.fileExists(atPath: configPath) {
            configPath.withCString { ghostty_config_load_file(cfg, $0) }
        }
        ghostty_config_finalize(cfg)
        self.config = cfg

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false

        runtime.wakeup_cb = { ud in
            guard let ud else { return }
            let mgr = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
            DispatchQueue.main.async { mgr.tick() }
        }

        // action_cb: (ghostty_app_t, ghostty_target_s, ghostty_action_s) -> Bool
        runtime.action_cb = { app, target, action in
            guard let app else { return false }
            guard let ud = ghostty_app_userdata(app) else { return false }
            let mgr = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
            return mgr.handleAction(target, action)
        }

        // read_clipboard_cb: (void* surfaceUD, ghostty_clipboard_e, void* state) -> Bool
        // API: ghostty_surface_complete_clipboard_request(surface, text, state, confirm)
        runtime.read_clipboard_cb = { ud, clipboard, state in
            guard let ud, let state else {
                NSLog("[e05] read_clipboard_cb: ud or state is nil")
                return false
            }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
            guard let surface = view.surface else { return false }
            let pasteboard = NSPasteboard.general
            guard let text = pasteboard.string(forType: .string) else {
                NSLog("[e05] read_clipboard_cb: no text in pasteboard")
                return false
            }
            NSLog("[e05] read_clipboard_cb: pasting %d chars", text.count)
            guard let cStr = strdup(text) else { return false }
            DispatchQueue.main.async {
                ghostty_surface_complete_clipboard_request(surface, cStr, state, true)
                free(cStr)
            }
            return true
        }

        // confirm_read_clipboard_cb: (void* surfaceUD, const char*, void* state, ghostty_clipboard_request_e) -> Void
        runtime.confirm_read_clipboard_cb = { ud, text, state, request in
            guard let ud, let state else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
            guard let surface = view.surface else { return }
            DispatchQueue.main.async {
                ghostty_surface_complete_clipboard_request(surface, text, state, true)
            }
        }

        // write_clipboard_cb: (void*, ghostty_clipboard_e, ghostty_clipboard_content_s*, size_t, bool) -> Void
        runtime.write_clipboard_cb = { ud, clipboard, content, contentLen, confirm in
            guard let content, contentLen > 0 else { return }
            // Find text/plain content
            for i in 0..<contentLen {
                let item = content[i]
                guard let mime = item.mime, let data = item.data else { continue }
                if String(cString: mime) == "text/plain" {
                    let str = String(cString: data)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(str, forType: .string)
                    return
                }
            }
        }

        // close_surface_cb: (void* surfaceUserdata, bool processAlive) -> Void
        // ud is the SURFACE's userdata (GhosttyTerminalView), not the app's.
        // See ghostty embedded.zig Surface.close(): func(self.userdata, process_alive)
        runtime.close_surface_cb = { ud, processAlive in
            guard let ud else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
            DispatchQueue.main.async {
                view.onClose?()
            }
        }

        self.app = ghostty_app_new(&runtime, cfg)
        guard self.app != nil else {
            NSLog("[e05] ghostty_app_new failed")
            return
        }
        NSLog("[e05] ghostty runtime initialized")
    }

    nonisolated deinit {
        // Note: app and config are nonisolated(unsafe) would be needed
        // for proper cleanup, but for now the app lives for the process lifetime
    }

    public func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func handleAction(
        _ target: ghostty_target_s,
        _ action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let surface = target.target.surface else { return false }
            guard let titlePtr = action.action.set_title.title else { return false }
            let title = String(cString: titlePtr)
            onSetTitle?(surface, title)
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // GUI notification for abnormal exit or wait_after_command.
            // The actual close is handled by close_surface_cb.
            // TODO: show overlay message like ghostty macOS app
            return false
        default:
            return false
        }
    }
}
