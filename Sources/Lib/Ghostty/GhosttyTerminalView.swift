import AppKit
import GhosttyKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "GhosttyFind")

/// NSView that hosts a single ghostty terminal surface with Metal rendering.
@MainActor
public final class GhosttyTerminalView: NSView, @preconcurrency NSTextInputClient {
  private let ghosttyApp: GhosttyApp
  public private(set) var surface: ghostty_surface_t?
  private var metalLayer: CAMetalLayer?
  private var markedTextStorage = NSMutableAttributedString()
  /// nil = outside keyDown, [] = inside keyDown (no text yet).
  /// This distinction lets insertText know whether to accumulate or send directly.
  private var keyTextAccumulator: [String]?

  public var onTitleChange: ((String) -> Void)?
  public var onClose: (() -> Void)?
  public var onFocusChanged: ((Bool) -> Void)?
  /// Fired when libghostty raises `GHOSTTY_ACTION_OPEN_URL` for this
  /// surface. Covers OSC 8 anchors, auto-detected URLs, and ⌘+click,
  /// all unified by libghostty into one action. The host decides
  /// whether the URL becomes a browser or finder pane.
  public var onOpenURL: ((URL) -> Void)?

  /// When true, surface is preserved when the view is removed from window.
  /// Used by undo close to keep the terminal alive while detached.
  public var keepSurfaceAlive = false

  public init(frame: NSRect, ghosttyApp: GhosttyApp) {
    self.ghosttyApp = ghosttyApp
    super.init(frame: frame)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  // MARK: - Layer

  public override func makeBackingLayer() -> CALayer {
    let layer = CAMetalLayer()
    layer.device = MTLCreateSystemDefaultDevice()
    layer.isOpaque = true
    layer.contentsScale = window?.backingScaleFactor ?? 2.0
    metalLayer = layer
    return layer
  }

  // MARK: - Surface Lifecycle

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      if surface != nil {
        // Re-entering view hierarchy (e.g. undo close): refresh size
        updateSize()
      } else {
        createSurface()
      }
    } else if !keepSurfaceAlive {
      destroySurface()
    }
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

    surface = ghostty_surface_new(app, &cfg)
    guard surface != nil else {
      logger.error("ghostty_surface_new failed")
      return
    }

    updateSize()
    if let scale = window?.backingScaleFactor {
      ghostty_surface_set_content_scale(surface, scale, scale)
    }
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

  // MARK: - Layout

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateSize()
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    guard let surface, let scale = window?.backingScaleFactor else { return }
    metalLayer?.contentsScale = scale
    ghostty_surface_set_content_scale(surface, scale, scale)
    updateSize()
  }

  private func updateSize() {
    guard let surface else { return }
    // Skip size forwarding while the view (or any ancestor) is hidden.
    // Column fold flips `pane.containerView.isHidden = true` and
    // shrinks the column's width constraint to `foldedColumnWidth`
    // (30pt), which otherwise pushes an extremely narrow cols/rows
    // figure into ghostty. For surfaces whose backing process has
    // already exited via wait-after-command, that reflow is
    // destructive: there is no live shell to rebuild the scrollback
    // when the column is expanded again, so the previously visible
    // scrollback appears lost. Holding the last live size across the
    // fold lets ghostty keep the preserved screen intact.
    guard !isHiddenOrHasHiddenAncestor else { return }
    let scale = window?.backingScaleFactor ?? 1.0
    let w = UInt32(bounds.width * scale)
    let h = UInt32(bounds.height * scale)
    guard w > 0, h > 0 else { return }
    ghostty_surface_set_size(surface, w, h)
  }

  /// Forward the current bounds to ghostty even if the last
  /// `setFrameSize` was suppressed by the hidden-ancestor guard in
  /// `updateSize`. Called by the column-fold path right after a pane
  /// is unhidden so ghostty redraws at the full width.
  public func resyncSurfaceSize() {
    updateSize()
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
  private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e, text: String?, composing: Bool = false)
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

    let result: Bool
    if shouldSendText, let text {
      let textHex = text.unicodeScalars.map { String(format: "0x%02X", $0.value) }.joined(separator: " ")
      let kc = String(format: "0x%02X", event.keyCode)
      logger.debug("[key] keyCode=\(kc, privacy: .public) action=\(action.rawValue) text=\"\(text, privacy: .public)\" hex=[\(textHex, privacy: .public)]")
      result = text.withCString { ptr in
        key.text = ptr
        return ghostty_surface_key(surface, key)
      }
    } else {
      let kc = String(format: "0x%02X", event.keyCode)
      logger.debug("[key] keyCode=\(kc, privacy: .public) action=\(action.rawValue) text=nil (raw=\(text ?? "nil", privacy: .public))")
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

  public func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
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
