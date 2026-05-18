import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "GhosttyApp")

/// Manages the ghostty runtime lifecycle: init, config, app, tick.
@MainActor
public final class GhosttyApp {
  private(set) var app: ghostty_app_t?
  private(set) var config: ghostty_config_t?

  public init() {
    let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
    guard initResult == 0 else {
      logger.error("ghostty_init failed: \(initResult)")
      return
    }

    guard let cfg = ghostty_config_new() else {
      logger.error("ghostty_config_new failed")
      return
    }
    let configPath = E05Paths.default.configDir.appendingPathComponent("config").path
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
    // libghostty invokes this synchronously from `ghostty_app_tick`,
    // which we drive on the main queue (see `wakeup_cb` below). The
    // `@MainActor` guarantee for `handleAction` therefore holds by
    // construction rather than by compiler-checked isolation — keep
    // the tick dispatch on the main queue if the runtime is rewired.
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
        logger.error("read_clipboard_cb: ud or state is nil")
        return false
      }
      let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
      guard let surface = view.surface else { return false }
      let pasteboard = NSPasteboard.general
      guard let text = pasteboard.string(forType: .string) else {
        logger.debug("read_clipboard_cb: no text in pasteboard")
        return false
      }
      logger.debug("read_clipboard_cb: pasting \(text.count) chars")
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
      logger.error("ghostty_app_new failed")
      return
    }
    logger.info("ghostty runtime initialized")
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
      guard let view = terminalView(for: target),
        let titlePtr = action.action.set_title.title,
        let title = String(validatingCString: titlePtr)
      else { return false }
      view.onTitleChange?(title)
      return true
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      // GUI notification for abnormal exit or wait_after_command.
      // The actual close is handled by close_surface_cb.
      // TODO: show overlay message like ghostty macOS app
      return false
    case GHOSTTY_ACTION_START_SEARCH:
      guard let view = terminalView(for: target) else { return false }
      let needle = action.action.start_search.needle.flatMap { String(validatingCString: $0) } ?? ""
      view.handleSearchStart(needle: needle)
      return true
    case GHOSTTY_ACTION_END_SEARCH:
      guard let view = terminalView(for: target) else { return false }
      view.handleSearchEnd()
      return true
    case GHOSTTY_ACTION_SEARCH_TOTAL:
      guard let view = terminalView(for: target) else { return false }
      let raw = action.action.search_total.total
      view.handleSearchTotal(raw >= 0 ? Int(raw) : nil)
      return true
    case GHOSTTY_ACTION_SEARCH_SELECTED:
      guard let view = terminalView(for: target) else { return false }
      let raw = action.action.search_selected.selected
      view.handleSearchSelected(raw >= 0 ? Int(raw) : nil)
      return true
    case GHOSTTY_ACTION_OPEN_URL:
      guard let view = terminalView(for: target) else {
        logger.error("[ghostty/open-url] no terminal view for target")
        return false
      }
      guard let urlPtr = action.action.open_url.url else {
        logger.error("[ghostty/open-url] payload had nil url pointer")
        return false
      }
      // libghostty hands the URL as a length-prefixed UTF-8 buffer
      // (the trailing byte is not guaranteed to be NUL), so build the
      // String from the explicit byte range rather than treating the
      // pointer as a C string.
      let len = Int(action.action.open_url.len)
      let urlString = urlPtr.withMemoryRebound(to: UInt8.self, capacity: len) {
        String(decoding: UnsafeBufferPointer(start: $0, count: len), as: UTF8.self)
      }
      guard let url = URL(string: urlString) else {
        logger.error(
          "[ghostty/open-url] URL(string:) rejected \(urlString, privacy: .public)")
        return false
      }
      view.onOpenURL?(url)
      return true
    default:
      return false
    }
  }

  /// Resolve the `GhosttyTerminalView` that owns the surface referenced
  /// by a runtime action target. Returns `nil` for app-scoped actions
  /// or when the surface has no userdata attached (e.g. mid-teardown).
  private func terminalView(for target: ghostty_target_s) -> GhosttyTerminalView? {
    guard let surface = target.target.surface,
      let ud = ghostty_surface_userdata(surface)
    else { return nil }
    return Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
  }
}
