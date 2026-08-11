import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "GhosttyFind")

/// NSView that hosts a single ghostty terminal surface with Metal rendering.
@MainActor
public final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
  private let ghosttyApp: GhosttyApp
  public private(set) var surface: ghostty_surface_t?
  private var markedTextStorage = NSMutableAttributedString()
  /// nil = outside keyDown, [] = inside keyDown (no text yet).
  /// This distinction lets insertText know whether to accumulate or send directly.
  private var keyTextAccumulator: [String]?

  /// Active keyboard link-hint overlay, or nil when hints aren't showing.
  /// While set, key and mouse events drive hint selection instead of the
  /// surface — see `GhosttyTerminalView+Hints`.
  var hintsOverlay: TerminalHintsOverlayView?

  public var onTitleChange: ((String) -> Void)?
  public var onClose: (() -> Void)?
  public var onFocusChanged: ((Bool) -> Void)?
  /// Fired when libghostty raises `GHOSTTY_ACTION_OPEN_URL` for this
  /// surface. Covers OSC 8 anchors, auto-detected URLs, and ⌘+click,
  /// all unified by libghostty into one action. The host decides
  /// whether the URL becomes a browser or finder pane.
  public var onOpenURL: ((URL) -> Void)?

  /// Fired when the surface's reported working directory actually
  /// changes (deduped against OSC 7's per-prompt re-emits). Lets the
  /// host persist a `cd` promptly so it survives a crash / force quit,
  /// not only a clean quit.
  public var onWorkingDirectoryChange: (() -> Void)?

  /// Current working directory of the surface's shell, updated from
  /// each `GHOSTTY_ACTION_PWD` (OSC 7 via shell integration). `nil`
  /// until the shell first reports one; read at session-save time so a
  /// restored pane can reopen in the same directory. Requires shell
  /// integration to be active — without OSC 7 only the launch dir is
  /// ever known.
  public private(set) var currentWorkingDirectory: String?

  /// Working directory to launch the surface in, supplied on restore.
  /// Consumed once in `createSurface` as the config's
  /// `working_directory`; `nil` lets the shell start in its default
  /// (inherited / home) directory.
  private let restoreWorkingDirectory: String?

  /// Path of a saved scrollback capture to replay, supplied on restore.
  /// Passed to the shell as `E05_RESTORE_SCROLLBACK_FILE`; the shell
  /// integration cats and deletes it before the first prompt. `nil` for
  /// fresh panes and for restores with nothing captured.
  private let restoreScrollbackPath: String?

  /// When true, surface is preserved when the view is removed from window.
  /// Used by undo close to keep the terminal alive while detached.
  public var keepSurfaceAlive = false

  /// Observer for `NSApplication.didChangeScreenParametersNotification`.
  /// `viewDidChangeBackingProperties` fires on backing scale change, but
  /// physically reconnecting a display (or any display arrangement
  /// change that does not move the window across scale boundaries) does
  /// not surface as a backing scale change, so the view's layer keeps
  /// its previous `contentsScale` while libghostty re-renders glyphs
  /// against the new screen — visually the cell size goes wrong until
  /// something else forces a resync. Listen at the application level
  /// and resync explicitly. `nonisolated(unsafe)` so the nonisolated
  /// deinit can read it for teardown; the token is a class reference
  /// and `NotificationCenter.removeObserver` is documented thread-safe.
  nonisolated(unsafe) private var screenParametersObserver: NSObjectProtocol?

  /// Backing scale most recently pushed to libghostty's content scale
  /// and the view's layer by `syncMetrics`. It only advances when a sync
  /// actually lands (never while hidden), so a pane that was parked
  /// across a display change re-applies the new scale on unhide via the
  /// `scale != lastSyncedScale` check. 0 = never synced.
  private var lastSyncedScale: CGFloat = 0

  /// `CGDirectDisplayID` last handed to `ghostty_surface_set_display_id`,
  /// which points the surface's renderer CVDisplayLink at the display it
  /// lives on so vsync runs at that display's refresh rate. 0 = never set.
  private var lastSyncedDisplayID: UInt32 = 0

  /// `CGDirectDisplayID` of the screen the window currently sits on, or
  /// 0 when undeterminable (off-screen window).
  private var currentDisplayID: UInt32 {
    guard let screen = window?.screen,
      let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return 0 }
    return num.uint32Value
  }

  public init(
    frame: NSRect, ghosttyApp: GhosttyApp, restoreWorkingDirectory: String? = nil,
    restoreScrollbackPath: String? = nil
  ) {
    self.ghosttyApp = ghosttyApp
    self.restoreWorkingDirectory = restoreWorkingDirectory
    self.restoreScrollbackPath = restoreScrollbackPath
    super.init(frame: frame)
    // Deliberately do NOT set `wantsLayer` or override `makeBackingLayer`.
    // libghostty's Metal renderer makes the view layer-hosting by
    // assigning its own IOSurfaceLayer to `self.layer` and then setting
    // `wantsLayer = true` (Metal.zig). Creating our own backing layer
    // first left that ghostty layer installed but orphaned our reference,
    // so our `contentsScale` updates hit a detached layer and the surface
    // rendered at the wrong scale after a display change.
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  deinit {
    // Defense in depth: `viewDidMoveToWindow(nil)` normally tears the
    // observer down, but a teardown path that skips it (e.g. abrupt
    // app termination, future retain cycle) would otherwise leave the
    // NotificationCenter entry behind.
    if let obs = screenParametersObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  // MARK: - Surface Lifecycle

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      if surface != nil {
        // Re-entering view hierarchy (e.g. undo close): resync metrics —
        // the observer is detached while the view is detached, so any
        // screen change that landed during the detached window may have
        // left the layer's contentsScale and the surface scale stale.
        syncMetrics()
      } else {
        createSurface()
      }
      attachScreenParametersObserver()
    } else {
      detachScreenParametersObserver()
      if !keepSurfaceAlive {
        destroySurface()
      }
    }
  }

  private func attachScreenParametersObserver() {
    guard screenParametersObserver == nil else { return }
    screenParametersObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // Defer to the next runloop turn so `window?.backingScaleFactor`
      // and `bounds` reflect the post-reconfiguration display rather
      // than whatever AppKit briefly reports during the change.
      DispatchQueue.main.async { [weak self] in
        self?.syncMetrics()
      }
    }
  }

  private func detachScreenParametersObserver() {
    guard let obs = screenParametersObserver else { return }
    NotificationCenter.default.removeObserver(obs)
    screenParametersObserver = nil
  }

  private func createSurface() {
    guard surface == nil, let app = ghosttyApp.app else { return }

    var cfg = ghostty_surface_config_new()
    cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
    cfg.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
    cfg.userdata = Unmanaged.passUnretained(self).toOpaque()

    if let scale = window?.backingScaleFactor {
      cfg.scale_factor = scale
    }

    // Hand the restored working directory to libghostty as the surface's
    // launch dir. The C string only needs to outlive the
    // `ghostty_surface_new` call (libghostty copies the path during
    // init), so build the surface inside the `withCString` scope. A nil
    // restore dir leaves `working_directory` unset, which lets
    // libghostty's `*-inherit-working-directory` seed it from the
    // focused surface instead — the desired behaviour for fresh panes.
    // Scrollback replay is handed to the shell through the environment:
    // e05-integration.{zsh,bash,fish} reads E05_RESTORE_SCROLLBACK_FILE, cats
    // the file before the first prompt, and deletes it. libghostty has
    // no API to write into a surface's screen, so the child process is
    // the only way text can reach it.
    var env: [ghostty_env_var_s] = []
    var envStrings: [UnsafeMutablePointer<CChar>] = []
    defer {
      for pointer in envStrings { free(pointer) }
    }
    if let path = restoreScrollbackPath,
      let key = strdup("E05_RESTORE_SCROLLBACK_FILE"),
      let value = strdup(path)
    {
      envStrings.append(key)
      envStrings.append(value)
      env.append(ghostty_env_var_s(key: key, value: value))
    }

    // The pointers only need to outlive `ghostty_surface_new`, which
    // copies the config during init — same contract as the cwd string.
    env.withUnsafeMutableBufferPointer { buf in
      if !buf.isEmpty {
        cfg.env_vars = buf.baseAddress
        cfg.env_var_count = buf.count
      }

      if let cwd = restoreWorkingDirectory {
        surface = cwd.withCString { ptr in
          cfg.working_directory = ptr
          return ghostty_surface_new(app, &cfg)
        }
      } else {
        surface = ghostty_surface_new(app, &cfg)
      }
    }
    guard surface != nil else {
      logger.error("ghostty_surface_new failed")
      return
    }

    syncMetrics()
  }

  private func destroySurface() {
    guard let s = surface else { return }
    ghostty_surface_set_focus(s, false)
    ghostty_surface_free(s)
    surface = nil
  }

  /// Explicitly release a detached surface (e.g. undo close timeout).
  /// Use when the view is not in the hierarchy so viewDidMoveToWindow won't fire.
  public func releaseDetachedSurface() {
    keepSurfaceAlive = false
    destroySurface()
  }

  /// Record the shell's reported working directory, delivered by
  /// `GhosttyApp`'s dispatch of the `GHOSTTY_ACTION_PWD` apprt action
  /// (OSC 7). Session save reads `currentWorkingDirectory` so a restored
  /// pane reopens here. Returns whether the value actually changed:
  /// shell integration re-emits OSC 7 on every prompt redraw (not only
  /// on `cd`), so the same path arrives repeatedly and callers skip
  /// redundant work on a no-op.
  @discardableResult
  func noteWorkingDirectoryChanged(_ pwd: String) -> Bool {
    guard pwd != currentWorkingDirectory else { return false }
    currentWorkingDirectory = pwd
    onWorkingDirectoryChange?()
    return true
  }

  // MARK: - Layout

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    syncMetrics()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    syncMetrics()
  }

  /// Bring libghostty's view in line with the current display in one
  /// step: the layer's `contentsScale`, libghostty's content scale (the
  /// DPI it renders glyphs at), its pixel size, and the display the
  /// renderer's CVDisplayLink targets. Driving all four from one
  /// backing-scale read keeps them from drifting apart. Called from every
  /// layout pass (`setFrameSize`), the backing-properties hook, the
  /// screen-parameters observer, surface creation, and the show/unfold
  /// path.
  ///
  /// Skips entirely while the view (or an ancestor) is hidden. Column
  /// fold flips `pane.containerView.isHidden = true` and shrinks the
  /// column to `foldedColumnWidth` (30pt); forwarding that tiny size
  /// would reflow ghostty and lose the preserved scrollback of an
  /// already-exited shell. `lastSyncedScale` / `lastSyncedDisplayID` only
  /// advance when a sync lands, so a pane parked across a display change
  /// re-applies everything on unhide.
  private func syncMetrics() {
    guard let surface else { return }
    guard !isHiddenOrHasHiddenAncestor else { return }
    let displayID = currentDisplayID
    let displayChanged = displayID != 0 && displayID != lastSyncedDisplayID
    if displayChanged {
      ghostty_surface_set_display_id(surface, displayID)
      lastSyncedDisplayID = displayID
    }
    guard let scale = window?.backingScaleFactor else { return }
    let w = UInt32(bounds.width * scale)
    let h = UInt32(bounds.height * scale)
    guard w > 0, h > 0 else { return }
    var scaleChanged = false
    if scale != lastSyncedScale {
      // `self.layer` is libghostty's own IOSurfaceLayer (it replaces the
      // view's layer on surface creation). ghostty sets that layer's
      // contentsScale only once, at creation, so we must keep it in step
      // with the window here or the high-resolution glyphs it renders get
      // composited at the stale scale — cells then look too large or
      // small after a display change. Wrapped in a no-action CATransaction
      // so Core Animation does not animate the change as a brief zoom.
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.contentsScale = scale
      CATransaction.commit()
      ghostty_surface_set_content_scale(surface, scale, scale)
      lastSyncedScale = scale
      scaleChanged = true
    }
    ghostty_surface_set_size(surface, w, h)
    // A focused surface only repaints on its CVDisplayLink vsync, which
    // may not fire for a frame or two right after a display change. Force
    // a synchronous main-thread draw on the transition so the corrected
    // scale shows immediately instead of flashing the stale frame
    // (libghostty supports drawing from the main thread for resizes).
    if displayChanged || scaleChanged {
      ghostty_surface_draw(surface)
    }
  }

  /// Re-forward metrics to ghostty after the pane is unhidden (column
  /// unfold / workspace switch). `syncMetrics` skips while hidden, so
  /// any scale or size change that landed while parked is applied here.
  public func resyncSurfaceSize() {
    syncMetrics()
  }

  /// Drop any stale focus flag on the ghostty surface. Column fold
  /// hides the pane without firing `resignFirstResponder`, so
  /// surfaces retain whatever focus value they held at fold time —
  /// leaving the caret blinking on the wrong pane after unfold.
  /// Call this before restoring first responder so only the newly
  /// focused surface re-arms via `becomeFirstResponder`.
  public func clearSurfaceFocus() {
    guard let surface else { return }
    ghostty_surface_set_focus(surface, false)
  }

  // MARK: - Focus

  public override var acceptsFirstResponder: Bool { true }

  public override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    if result {
      ghostty_surface_set_focus(surface, true)
      onFocusChanged?(true)
    }
    return result
  }

  public override func resignFirstResponder() -> Bool {
    let result = super.resignFirstResponder()
    if result {
      // Tear down link hints on real focus loss so a stale overlay can't
      // outlive a detach (undo close) or workspace switch and silently
      // swallow keystrokes after the view comes back. Showing hints keeps
      // this view first responder, so this doesn't fire on show.
      dismissLinkHints()
      ghostty_surface_set_focus(surface, false)
      onFocusChanged?(false)
    }
    return result
  }

  // MARK: - Key Input

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self else { return false }

    switch event.keyCode {
    case 0x35:  // ESC — prevent parent views from consuming it
      keyDown(with: event)
      return true
    default:
      break
    }

    return false
  }

  public override func keyDown(with event: NSEvent) {
    guard surface != nil else { return }

    // Link hints own the keyboard while up: a letter picks a hint, Esc or
    // anything else cancels. Don't forward to the surface.
    if hintsOverlay != nil {
      handleHintKey(event)
      return
    }

    let action: ghostty_input_action_e =
      event.isARepeat
      ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

    // Command key: send without text (for keybinds)
    guard !event.modifierFlags.contains(.command) else {
      sendKeyEvent(event, action: action, text: nil, composing: false)
      return
    }

    // Record IME state before interpretKeyEvents
    let markedTextBefore = hasMarkedText()

    // Collect text via input method system
    keyTextAccumulator = []
    interpretKeyEvents([event])
    let accumulated = keyTextAccumulator ?? []
    keyTextAccumulator = nil

    // Sync preedit state after interpretKeyEvents
    syncPreedit(clearIfNeeded: markedTextBefore)

    // IME composing: tell ghostty not to encode this key
    let composing = hasMarkedText() || markedTextBefore

    // If text was collected (IME confirmed or normal input), send with text
    if !accumulated.isEmpty {
      for text in accumulated {
        sendKeyEvent(event, action: action, text: text, composing: false)
      }
      return
    }

    // No text collected — send with derived characters (or composing=true to suppress)
    let chars = composing ? nil : GhosttyInput.ghosttyCharacters(from: event)
    sendKeyEvent(event, action: action, text: chars, composing: composing)
  }

  public override func keyUp(with event: NSEvent) {
    guard surface != nil else { return }
    sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE, text: nil)
  }

  public override func flagsChanged(with event: NSEvent) {
    guard surface != nil else { return }
    let isPress = isModifierPress(event)
    let action: ghostty_input_action_e =
      isPress
      ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
    sendKeyEvent(event, action: action, text: nil)
  }

  @discardableResult
  private func sendKeyEvent(
    _ event: NSEvent, action: ghostty_input_action_e, text: String?, composing: Bool = false
  )
    -> Bool
  {
    guard let surface else { return false }
    var key = GhosttyInput.keyEvent(from: event, action: action)
    key.composing = composing

    // Match Ghostty's own behavior: only send text for printable characters
    // (codepoint >= 0x20). Control characters are encoded by ghostty itself
    // based on the keycode.
    let shouldSendText: Bool
    if let text, !text.isEmpty,
      let codepoint = text.utf8.first, codepoint >= 0x20
    {
      shouldSendText = true
    } else {
      shouldSendText = false
    }

    // The hex renderings are built inside the log interpolation so
    // os.Logger's autoclosure defers them: this is the keystroke hot
    // path, and with debug logging off the `String(format:)` work never
    // runs.
    let result: Bool
    if shouldSendText, let text {
      logger.debug(
        "[key] keyCode=\(String(format: "0x%02X", event.keyCode), privacy: .public) action=\(action.rawValue) text=\"\(text, privacy: .public)\" hex=[\(text.unicodeScalars.map { String(format: "0x%02X", $0.value) }.joined(separator: " "), privacy: .public)]"
      )
      result = text.withCString { ptr in
        key.text = ptr
        return ghostty_surface_key(surface, key)
      }
    } else {
      logger.debug(
        "[key] keyCode=\(String(format: "0x%02X", event.keyCode), privacy: .public) action=\(action.rawValue) text=nil (raw=\(text ?? "nil", privacy: .public))"
      )
      result = ghostty_surface_key(surface, key)
    }
    return result
  }

  private func isModifierPress(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags
    switch event.keyCode {
    case 0x38, 0x3C: return flags.contains(.shift)
    case 0x3A, 0x3D: return flags.contains(.option)
    case 0x3B, 0x3E: return flags.contains(.control)
    case 0x37, 0x36: return flags.contains(.command)
    case 0x39: return flags.contains(.capsLock)
    default: return false
    }
  }

  // MARK: - Mouse

  public override func mouseDown(with event: NSEvent) {
    guard let surface else { return }
    // A click anywhere dismisses link hints instead of reaching the shell.
    if hintsOverlay != nil {
      dismissLinkHints()
      return
    }
    ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS,
      GHOSTTY_MOUSE_LEFT,
      GhosttyInput.ghosttyMods(event.modifierFlags))
  }

  public override func mouseUp(with event: NSEvent) {
    guard let surface else { return }
    ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE,
      GHOSTTY_MOUSE_LEFT,
      GhosttyInput.ghosttyMods(event.modifierFlags))
  }

  public override func mouseMoved(with event: NSEvent) {
    updateMousePos(event)
  }

  public override func mouseDragged(with event: NSEvent) {
    updateMousePos(event)
  }

  public override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    // Scrolling moves content out from under the fixed hint badges, so drop
    // them rather than leave them pointing at the wrong rows.
    if hintsOverlay != nil {
      dismissLinkHints()
      return
    }
    ghostty_surface_mouse_scroll(
      surface,
      event.scrollingDeltaX,
      event.scrollingDeltaY,
      ghostty_input_scroll_mods_t(GhosttyInput.ghosttyMods(event.modifierFlags).rawValue))
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self
      ))
  }

  private func updateMousePos(_ event: NSEvent) {
    guard let surface else { return }
    let pos = convertToSurface(event.locationInWindow)
    ghostty_surface_mouse_pos(
      surface, pos.x, pos.y,
      GhosttyInput.ghosttyMods(event.modifierFlags))
  }

  private func convertToSurface(_ windowPoint: NSPoint) -> NSPoint {
    let local = convert(windowPoint, from: nil)
    return NSPoint(x: local.x, y: bounds.height - local.y)
  }

  // MARK: - AppKit Text Command Handling

  /// Called by interpretKeyEvents when a key maps to a text command
  /// (e.g. ESC → cancelOperation:, Enter → insertNewline:).
  /// Terminal views should NOT execute these commands — the raw key
  /// events are sent to ghostty instead.
  public override func doCommand(by selector: Selector) {
    logger.debug("doCommand(by: \(NSStringFromSelector(selector), privacy: .public))")
    // Intentionally do nothing. Without this, AppKit sends the command
    // up the responder chain, which can cause hangs (e.g. cancelOperation: for ESC).
  }

  // MARK: - NSTextInputClient

  public func insertText(_ string: Any, replacementRange _: NSRange) {
    let text: String
    if let s = string as? String {
      text = s
    } else if let s = string as? NSAttributedString {
      text = s.string
    } else {
      return
    }

    unmarkText()

    // Inside keyDown: accumulate for sendKeyEvent
    if keyTextAccumulator != nil {
      keyTextAccumulator?.append(text)
      return
    }

    // Outside keyDown (e.g. drag-and-drop): send directly to PTY
    guard let surface else { return }
    logger.debug("[key] insertText outside keyDown: \"\(text, privacy: .public)\"")
    text.withCString { ptr in
      ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
    }
  }

  public func setMarkedText(_ string: Any, selectedRange _: NSRange, replacementRange _: NSRange) {
    if let s = string as? String {
      markedTextStorage.mutableString.setString(s)
    } else if let s = string as? NSAttributedString {
      markedTextStorage.setAttributedString(s)
    }
    // If called outside keyDown (e.g. keyboard layout change), sync immediately
    if keyTextAccumulator == nil {
      syncPreedit()
    }
  }

  public func unmarkText() {
    guard markedTextStorage.length > 0 else { return }
    markedTextStorage.mutableString.setString("")
    syncPreedit()
  }

  private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }
    if markedTextStorage.length > 0 {
      let text = markedTextStorage.string
      text.withCString { ptr in
        ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  public func selectedRange() -> NSRange {
    NSRange(location: NSNotFound, length: 0)
  }

  public func markedRange() -> NSRange {
    markedTextStorage.length > 0
      ? NSRange(location: 0, length: markedTextStorage.length)
      : NSRange(location: NSNotFound, length: 0)
  }

  public func hasMarkedText() -> Bool {
    markedTextStorage.length > 0
  }

  public func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?)
    -> NSAttributedString?
  {
    nil
  }

  public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    []
  }

  public func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
    guard let windowFrame = window?.frame else { return .zero }
    let local = convert(bounds, to: nil)
    return NSRect(
      x: windowFrame.origin.x + local.origin.x,
      y: windowFrame.origin.y + local.origin.y,
      width: 0,
      height: 0
    )
  }

  public func characterIndex(for _: NSPoint) -> Int {
    0
  }

  // MARK: - Search

  /// Latest search needle observed on this surface. Driven by
  /// `GHOSTTY_ACTION_START_SEARCH` notifications from libghostty and
  /// cleared by `GHOSTTY_ACTION_END_SEARCH`. libghostty emits
  /// start_search with an empty needle to signal "open the search UI"
  /// — the actual query is threaded in through the `search:<needle>`
  /// binding action, which is echoed back as the same notification.
  internal private(set) var searchNeedle: String = ""

  /// Match count reported by the libghostty search thread. `nil`
  /// means the scan is in-flight or indeterminate (libghostty wraps
  /// `?usize` as `-1` on the C boundary and we restore the optional
  /// here). Updated on every `GHOSTTY_ACTION_SEARCH_TOTAL`.
  internal private(set) var searchTotal: Int?

  /// 0-based index of the currently highlighted match as reported by
  /// libghostty, or `nil` when no match is selected (no navigation
  /// yet, or scan pending). `flushPendingFindCompletion` converts
  /// this to the 1-based count `FindHelper` callers expect.
  internal private(set) var searchSelected: Int?

  /// Caller deferred until the next `search_total` / `search_selected`
  /// callback lands (or the fallback timer fires). Set from
  /// `performFind`, drained from `flushPendingFindCompletion`.
  private var pendingFindCompletion: (@MainActor ((total: Int, current: Int)) -> Void)?

  /// Safety net for queries where libghostty stays silent — a
  /// zero-match needle emits no `search_selected`, and a same-needle
  /// retry may skip `search_total`. The timer guarantees the caller
  /// isn't left waiting on a notification that will never arrive.
  private var findCompletionTimer: Timer?

  func handleSearchStart(needle: String) {
    // Guard against a same-needle re-entry so future `didSet`-based
    // scan resets or logging side effects on `searchNeedle` can be
    // attached without triggering on a no-op reassignment. libghostty
    // only fires START_SEARCH from ghostty's own ⌘F binding (the
    // `search:<needle>` path suppresses it), so the redundant case
    // is rare today — but cheap to rule out here rather than at every
    // future observer site.
    guard needle != searchNeedle else { return }
    searchNeedle = needle
    logger.debug("start_search needle=\"\(needle, privacy: .public)\"")
  }

  func handleSearchEnd() {
    searchNeedle = ""
    searchTotal = nil
    searchSelected = nil
    logger.debug("end_search")
    flushPendingFindCompletion()
  }

  func handleSearchTotal(_ total: Int?) {
    logger.debug("search_total=\(total.map(String.init) ?? "nil", privacy: .public)")
    // libghostty emits `total=0` / `total=null` as a reset
    // notification before every scan and after `navigate_search`
    // transitions. Keep the previous observed count so the fallback
    // timer doesn't flush with zero after the reset; the real count
    // (or `null` from a genuinely zero-match needle) arrives in a
    // subsequent notification that we do honour below.
    guard let total, total > 0 else { return }
    searchTotal = total
    flushPendingFindCompletion()
  }

  func handleSearchSelected(_ selected: Int?) {
    logger.debug("search_selected=\(selected.map(String.init) ?? "nil", privacy: .public)")
    // `selected=null` is the reset counterpart to `total=0` and is
    // pushed by libghostty whenever the selection state is being
    // recomputed (needle change, navigate_search, etc.). Keep the
    // prior selected index until a concrete one lands.
    guard let selected else { return }
    searchSelected = selected
    flushPendingFindCompletion()
  }

  /// Forward a binding action string (e.g. `search:foo`,
  /// `navigate_search:next`, `end_search`) to libghostty on this
  /// surface. The third argument to `ghostty_surface_binding_action`
  /// is the action-string byte length — passing a zero there yields
  /// an empty slice and a parse error inside libghostty.
  @discardableResult
  private func performSearchAction(_ action: String) -> Bool {
    guard let surface else { return false }
    return action.withCString { ptr in
      ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
    }
  }

  /// Drain any in-flight find completion using the latest observed
  /// total / selected values. Safe to call repeatedly — the second
  /// call is a no-op because the completion slot is cleared on the
  /// first flush.
  private func flushPendingFindCompletion() {
    guard let pending = pendingFindCompletion else { return }
    pendingFindCompletion = nil
    findCompletionTimer?.invalidate()
    findCompletionTimer = nil
    // libghostty returns selected as a 0-based index; FindBar and
    // the FindHelper protocol expect a 1-based count to match
    // Brave / Chrome / Firefox conventions. Translate here so the
    // stored state stays faithful to the upstream representation.
    let position: (total: Int, current: Int) = (
      total: searchTotal ?? 0,
      current: searchSelected.map { $0 + 1 } ?? 0
    )
    Task { @MainActor in pending(position) }
  }
}

// MARK: - FindHelper

extension GhosttyTerminalView: FindHelper {
  /// Drive the libghostty scrollback search via binding actions. A
  /// fresh `needle` kicks `search:<needle>` which triggers a scan on
  /// the ghostty side and produces a `search_total` callback when
  /// the scan completes. Subsequent calls with the same needle send
  /// `navigate_search:next` / `previous`, which update the selected
  /// match and emit `search_selected`. Completion is deferred until
  /// either callback flushes it or the short fallback timer expires,
  /// so zero-match queries don't leave the caller hanging.
  public func performFind(
    _ needle: String,
    forward: Bool,
    completion: @escaping @MainActor ((total: Int, current: Int)) -> Void
  ) {
    guard !needle.isEmpty else {
      endFind()
      Task { @MainActor in completion((total: 0, current: 0)) }
      return
    }

    // Reject any prior completion so a stale caller can't latch onto
    // a response for a different needle.
    flushPendingFindCompletion()
    pendingFindCompletion = completion

    let action: String
    if needle == searchNeedle, searchTotal != nil {
      action = forward ? "navigate_search:next" : "navigate_search:previous"
    } else {
      // Changing the needle invalidates prior counts; clear before
      // the scan so a fast keystroke doesn't flush with stale values.
      // Record the needle locally too: libghostty only emits
      // `start_search` for its own ⌘F binding, so without this the
      // `searchNeedle == needle` branch above would never be taken
      // and every ⌘G would re-send `search:<needle>` and reset the
      // counts instead of navigating.
      searchNeedle = needle
      searchTotal = nil
      searchSelected = nil
      action = "search:\(needle)"
    }

    performSearchAction(action)

    findCompletionTimer?.invalidate()
    findCompletionTimer = Timer.scheduledTimer(
      withTimeInterval: 0.15, repeats: false
    ) { [weak self] _ in
      DispatchQueue.main.async { self?.flushPendingFindCompletion() }
    }
  }

  public func endFind() {
    performSearchAction("end_search")
    findCompletionTimer?.invalidate()
    findCompletionTimer = nil
    pendingFindCompletion = nil
  }
}
