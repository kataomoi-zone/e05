import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "GhosttyApp")

/// Answer a clipboard read with `text` as its text/plain representation
/// (or none), listing text/plain as available when `listsText`.
/// libghostty borrows the buffers only for the duration of the call.
private func completeClipboardRequest(
  _ surface: ghostty_surface_t,
  text: String?,
  state: UnsafeMutableRawPointer?,
  listsText: Bool
) {
  // A byte copy rather than strdup: the length is explicit, and text
  // holding a NUL would make strdup stop short of it. Never empty, so
  // an empty paste still hands over a non-null pointer.
  let bytes = Array((text ?? "").utf8)
  let buffer = bytes.isEmpty ? [0] : bytes
  "text/plain".withCString { mime in
    buffer.withUnsafeBufferPointer { data in
      data.withMemoryRebound(to: CChar.self) { data in
        let contents =
          text == nil
          ? [] : [ghostty_clipboard_content_s(mime: mime, data: data.baseAddress, len: bytes.count)]
        let available: [UnsafePointer<CChar>?] = listsText ? [mime] : []
        contents.withUnsafeBufferPointer { contentsBuf in
          available.withUnsafeBufferPointer { availableBuf in
            var complete = ghostty_clipboard_complete_s(
              contents: contentsBuf.baseAddress,
              contents_len: contentsBuf.count,
              available: availableBuf.baseAddress,
              available_len: availableBuf.count,
              confirmed: false,
              remember: false)
            ghostty_surface_complete_clipboard_request(surface, &complete, state)
          }
        }
      }
    }
  }
}

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

  /// Whether quitting needs a "running process" confirmation: true if
  /// any live surface reports unfinished work. libghostty folds the
  /// `confirm-close-surface` config, read-only state, child-exit state,
  /// and shell-integration prompt position into this single answer, so
  /// the app-quit path doesn't reimplement the policy. False when the
  /// app handle is gone (nothing to confirm).
  public var needsConfirmQuit: Bool {
    guard let app else { return false }
    return ghostty_app_needs_confirm_quit(app)
  }

  /// Point libghostty at the resources bundled inside the app
  /// (themes / shell-integration / terminfo) before `ghostty_init`.
  /// A release launched from Finder inherits no `GHOSTTY_RESOURCES_DIR`
  /// from a parent ghostty process, so without this the built-in themes
  /// and the `xterm-ghostty` terminfo can't be resolved. The bundle copy
  /// is forced to win over any inherited value so the resources always
  /// match the embedded libghostty version. terminfo lives beside the
  /// resources dir (ghostty resolves it adjacent to `GHOSTTY_RESOURCES_DIR`),
  /// so the sentinel check probes the sibling `terminfo/78/xterm-ghostty`.
  private static func configureBundledResourcesDir() {
    guard let resourceURL = Bundle.main.resourceURL else {
      logger.warning(
        "[ghostty/resources] Bundle.main.resourceURL is nil; relying on inherited GHOSTTY_RESOURCES_DIR"
      )
      return
    }
    let sentinel = resourceURL.appendingPathComponent("terminfo/78/xterm-ghostty")
    guard FileManager.default.fileExists(atPath: sentinel.path) else {
      logger.warning(
        "[ghostty/resources] bundled terminfo missing at \(sentinel.path); built-in themes and xterm-ghostty terminfo are unavailable unless GHOSTTY_RESOURCES_DIR is inherited"
      )
      return
    }
    let ghosttyDir = resourceURL.appendingPathComponent("ghostty").path
    if setenv("GHOSTTY_RESOURCES_DIR", ghosttyDir, 1) != 0 {
      logger.error(
        "[ghostty/resources] setenv GHOSTTY_RESOURCES_DIR failed: \(String(cString: strerror(errno)))"
      )
    }
  }

  /// Expose the bundled `Contents/Resources/bin` to ghostty surfaces
  /// so the `open` shim (Resources/bin/open) shadows /usr/bin/open and
  /// `open .` / `open https://...` lands as a pane on the host:
  ///   - E05_BIN_DIR, read by the shell-integration PATH fix
  ///     (Resources/bin/e05-integration.{zsh,bash,fish}). It re-prepends
  ///     this dir from a prompt hook, which runs after a login shell's
  ///     path_helper has reordered PATH — the only reliable way to
  ///     keep the shim ahead of /usr/bin. The exported PATH is
  ///     inherited by child processes too. Its absence also turns the
  ///     whole integration off, scrollback replay included.
  ///   - PATH prepend here, the fallback for shells that don't load
  ///     the integration (non-interactive, or unsupported shells).
  /// Skipped when the directory is absent so `swift run` and other
  /// non-bundled launches keep stock PATH; the `contains` gate makes
  /// the PATH inject idempotent against future re-init paths.
  private static func configureBundledBinDir() {
    guard let resourceURL = Bundle.main.resourceURL else { return }
    let binDir = resourceURL.appendingPathComponent("bin").path
    guard FileManager.default.fileExists(atPath: binDir) else { return }
    // Set unconditionally: the integration's PATH fix reads it to
    // know what to prepend, and it gates the fix to e05 (the var is
    // unset in any shell e05 didn't spawn).
    if setenv("E05_BIN_DIR", binDir, 1) != 0 {
      logger.error("[app/path-inject] setenv E05_BIN_DIR failed errno=\(errno)")
    }
    let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let alreadyInjected = current.split(separator: ":").contains(Substring(binDir))
    if !alreadyInjected {
      if setenv("PATH", "\(binDir):\(current)", 1) != 0 {
        logger.error("[app/path-inject] setenv PATH failed errno=\(errno)")
      }
    }
  }

  public init() {
    // Both before `ghostty_init`, never after: libghostty snapshots
    // `environ` there and builds every shell's environment from that
    // snapshot, so a later setenv is invisible to surfaces — and can
    // reallocate the array the snapshot still points into.
    Self.configureBundledResourcesDir()
    Self.configureBundledBinDir()
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

    // read_clipboard_cb: (void* surfaceUD, ghostty_clipboard_e, void* state,
    //   const char* const* mimes, size_t mimesLen, bool list) -> read result
    // Every location is the general pasteboard, as in write_clipboard_cb,
    // so `paste_from_selection` keeps pasting it. Only text/plain: that is
    // what paste and OSC 52 ask for. LIMITATION: a Kitty clipboard read
    // for another type, or a listing of the available types, sees
    // text/plain at most.
    runtime.read_clipboard_cb = { ud, clipboard, state, mimes, mimesLen, list in
      guard let ud else {
        logger.error("read_clipboard_cb: ud is nil")
        return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
      }
      let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
      guard let surface = view.surface else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
      let pasteboard = NSPasteboard.general
      let wantsText =
        mimes.map { mimes in
          (0..<mimesLen).contains { i in mimes[i].map { String(cString: $0) } == "text/plain" }
        } ?? false
      let text = wantsText ? pasteboard.string(forType: .string) : nil
      if text == nil && !list {
        logger.debug("read_clipboard_cb: no text in pasteboard")
        return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
      }
      // Name text/plain as available without reading it, for a listing
      // that asks for no types (a paste event's).
      let listsText =
        list && (text != nil || pasteboard.availableType(from: [.string]) != nil)
      logger.debug("read_clipboard_cb: serving \(text?.count ?? 0) chars")
      completeClipboardRequest(surface, text: text, state: state, listsText: listsText)
      return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    // confirm_read_clipboard_cb: (void* surfaceUD, const ghostty_clipboard_confirm_s*,
    //   void* state, ghostty_clipboard_request_e) -> Void
    // libghostty asks here before an unsafe paste, an OSC 52 read, or a
    // Kitty clipboard read or write that its config says to ask about.
    // LIMITATION: e05 has no prompt, so every such request is approved
    // with exactly the contents libghostty proposed, the same way
    // write_clipboard_cb below ignores its `confirm` flag.
    runtime.confirm_read_clipboard_cb = { ud, confirm, state, request in
      guard let ud else { return }
      let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ud).takeUnretainedValue()
      guard let surface = view.surface else { return }
      guard let confirm else {
        ghostty_surface_deny_clipboard_request(surface, state)
        return
      }
      var complete = ghostty_clipboard_complete_s(
        contents: confirm.pointee.contents,
        contents_len: confirm.pointee.contents_len,
        available: confirm.pointee.available,
        available_len: confirm.pointee.available_len,
        confirmed: true,
        remember: false)
      ghostty_surface_complete_clipboard_request(surface, &complete, state)
    }

    // write_clipboard_cb: (void*, ghostty_clipboard_e, ghostty_clipboard_content_s*, size_t, bool) -> Void
    // Takes the first text entry. A Kitty clipboard write keeps the
    // program's own MIME name, so the text aliases are the ones ghostty's
    // `terminal.clipboard.isTextMime` accepts. LIMITATION: a write with no
    // text entry (an image alone) leaves the pasteboard as it was.
    runtime.write_clipboard_cb = { ud, clipboard, content, contentLen, confirm in
      guard let content, contentLen > 0 else { return }
      let textMimes: Set = [
        "text/plain", "text/plain;charset=utf-8", "UTF8_STRING", "TEXT", "STRING",
      ]
      for i in 0..<contentLen {
        let item = content[i]
        guard let mime = item.mime, let data = item.data else { continue }
        if textMimes.contains(String(cString: mime)) {
          // Length-delimited, not NUL-terminated.
          let str = String(
            decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
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

  /// Force libghostty to re-read `config.ghostty` from disk and fan
  /// the resulting config out to every live surface. Triggered by
  /// the Terminal settings tab after a Save so an edit takes effect
  /// without an app restart. Returns whether the reload succeeded;
  /// `false` is logged at the failure site so callers do not need
  /// to surface the error themselves.
  @discardableResult
  public func reloadConfigFromDisk() -> Bool {
    reloadAppConfig(soft: false)
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
    case GHOSTTY_ACTION_PWD:
      guard let view = terminalView(for: target),
        let pwdPtr = action.action.pwd.pwd,
        let pwd = String(validatingCString: pwdPtr)
      else { return false }
      view.sendPendingStartupCommand()
      // Shell integration re-emits OSC 7 on every prompt redraw, so log
      // only when the directory actually moves to keep the noise down.
      if view.noteWorkingDirectoryChanged(pwd) {
        logger.debug("[ghostty/pwd] surface cwd=\(pwd, privacy: .public)")
      }
      return true
    case GHOSTTY_ACTION_COMMAND_FINISHED:
      // Raised only for a command whose start (OSC 133 C) was seen, so
      // the first prompt of a fresh shell never trips it.
      guard let view = terminalView(for: target) else { return false }
      view.noteCommandFinished()
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
      // What libghostty matched, before e05 interprets it. The payload
      // is the only place the raw match is visible, and how far a match
      // runs (a wrapped row, a space in a path) is the first question
      // whenever a click opens the wrong thing.
      logger.debug("[ghostty/open-url] payload=\(urlString, privacy: .public)")
      // A detected filesystem path arrives as written, with no scheme,
      // and `URL(string:)` hands back something whose `isFileURL` is
      // false — the pane router would read it as an unknown address and
      // open a blank browser. Build a file URL the way the hint overlay
      // does for the same text. A relative path is left alone: it would
      // resolve against e05's own working directory, not the shell's.
      let url: URL
      if urlString.hasPrefix("/") || urlString.hasPrefix("~") {
        url = URL(fileURLWithPath: (urlString as NSString).expandingTildeInPath)
      } else if let parsed = URL(string: urlString) {
        url = parsed
      } else {
        logger.error(
          "[ghostty/open-url] URL(string:) rejected \(urlString, privacy: .public)")
        return false
      }
      // A ⌘-click fires OPEN_URL synchronously from inside libghostty's
      // mouse handling, while the surface lock is held. Opening the URL
      // adds a column and refocuses a surface, which re-enters libghostty
      // and tries to take that same lock recursively — an os_unfair_lock
      // abort. Defer so the click unwinds and the lock releases first.
      DispatchQueue.main.async { view.onOpenURL?(url) }
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
