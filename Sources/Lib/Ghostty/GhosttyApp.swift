import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "GhosttyApp")

/// Light / dark hint forwarded to libghostty so a
/// `theme = light:X,dark:Y` config swaps the color scheme without an
/// app restart. The host owns the appearance observer because
/// libghostty does not link AppKit; the official ghostty macOS app
/// uses the same NSApp.effectiveAppearance KVO → C API hop.
public enum GhosttyColorScheme: Sendable, Equatable {
  case light
  case dark

  /// Resolve a system `NSAppearance` to the light/dark axis the
  /// terminal cares about. `bestMatch` collapses high-contrast
  /// accessibility variants (`accessibilityHighContrastDarkAqua`
  /// etc.) to their closest standard form.
  public init(_ appearance: NSAppearance) {
    let match = appearance.bestMatch(from: [.aqua, .darkAqua])
    self = (match == .darkAqua) ? .dark : .light
  }

  var cValue: ghostty_color_scheme_e {
    switch self {
    case .light: GHOSTTY_COLOR_SCHEME_LIGHT
    case .dark: GHOSTTY_COLOR_SCHEME_DARK
    }
  }
}

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
    let configPath = E05Paths.default.configFile(E05Filenames.terminalConfig).path
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

  /// Forward the host's resolved light/dark appearance to libghostty.
  /// Stored on the runtime even before any surface exists, so the
  /// first ghostty surface created after launch picks up the correct
  /// `light:` / `dark:` branch of a conditional `theme` config.
  ///
  /// The app-level state alone is not enough to repaint existing
  /// surfaces: each surface keeps its own `config_conditional_state`
  /// that was seeded at creation. Call
  /// ``setSurfaceColorScheme(surface:scheme:)`` on every live surface
  /// so the surface's derived config re-resolves the conditional
  /// `theme` branch.
  public func setColorScheme(_ scheme: GhosttyColorScheme) {
    guard let app else { return }
    ghostty_app_set_color_scheme(app, scheme.cValue)
  }

  /// Update a single surface's conditional `theme` state. libghostty
  /// will bounce a `reload_config` action back to the host with the
  /// surface target, which ``handleAction`` resolves through
  /// ``reloadSurfaceConfig`` to actually re-derive the surface's
  /// colors.
  public func setSurfaceColorScheme(
    surface: ghostty_surface_t,
    scheme: GhosttyColorScheme
  ) {
    ghostty_surface_set_color_scheme(surface, scheme.cValue)
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
    case GHOSTTY_ACTION_RELOAD_CONFIG:
      let soft = action.action.reload_config.soft
      switch target.tag {
      case GHOSTTY_TARGET_APP:
        return reloadAppConfig(soft: soft)
      case GHOSTTY_TARGET_SURFACE:
        guard let surface = target.target.surface else {
          logger.error("[ghostty/reload-config] surface target had nil surface")
          return false
        }
        return reloadSurfaceConfig(surface: surface, soft: soft)
      default:
        logger.error(
          "[ghostty/reload-config] unknown target tag rawValue=\(target.tag.rawValue, privacy: .public)"
        )
        return false
      }
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

  /// Pump a new configuration through libghostty so every existing
  /// surface re-derives its colors. Triggered by libghostty itself
  /// after `ghostty_app_set_color_scheme` or the `reload_config`
  /// keybind: the runtime stages the conditional state change and
  /// then bounces a `reload_config` action back to the host, expecting
  /// the host to do the actual `ghostty_app_update_config` fan-out.
  ///
  /// A `soft` reload re-passes the in-memory config (cheap, used for
  /// the light/dark flip). A non-soft reload re-reads
  /// `config.ghostty` from disk, finalises a fresh config, hands it
  /// to libghostty, and frees the previous one — `updateConfig` only
  /// reads the pointer for the duration of the call, so transferring
  /// ownership is safe.
  private func reloadAppConfig(soft: Bool) -> Bool {
    guard let app else {
      logger.error("[ghostty/reload-config] app handle is nil")
      return false
    }
    if soft {
      guard let config else {
        logger.error("[ghostty/reload-config] soft reload requested with nil config")
        return false
      }
      ghostty_app_update_config(app, config)
      return true
    }
    guard let next = loadConfigFromDisk() else { return false }
    ghostty_app_update_config(app, next)
    if let old = self.config {
      ghostty_config_free(old)
    }
    self.config = next
    return true
  }

  /// Surface-scoped variant. Re-derives only the targeted surface's
  /// colors. Fires when `ghostty_surface_set_color_scheme` bounces a
  /// `reload_config` (target=surface) back to the host, which is how
  /// per-surface conditional state — seeded at surface creation and
  /// not touched by app-level color scheme updates — gets refreshed.
  private func reloadSurfaceConfig(
    surface: ghostty_surface_t,
    soft: Bool
  ) -> Bool {
    if soft {
      guard let config else {
        logger.error("[ghostty/reload-config] surface soft reload requested with nil config")
        return false
      }
      ghostty_surface_update_config(surface, config)
      return true
    }
    guard let next = loadConfigFromDisk() else { return false }
    ghostty_surface_update_config(surface, next)
    ghostty_config_free(next)
    return true
  }

  /// Build a freshly parsed `ghostty_config_t` from the on-disk
  /// `config.ghostty`. Returns `nil` if libghostty refused to
  /// allocate; an absent or unreadable file is tolerated and yields
  /// a finalised default config so the host can recover from a hand
  /// edit that introduced a syntax error.
  private func loadConfigFromDisk() -> ghostty_config_t? {
    guard let next = ghostty_config_new() else {
      logger.error("[ghostty/reload-config] ghostty_config_new failed")
      return nil
    }
    let configPath = E05Paths.default.configFile(E05Filenames.terminalConfig).path
    if FileManager.default.fileExists(atPath: configPath) {
      configPath.withCString { ghostty_config_load_file(next, $0) }
    }
    ghostty_config_finalize(next)
    return next
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
