import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FindBar")

/// Floating pill shown over the focused pane for incremental
/// find-in-page. Hosted in a child NSPanel anchored to the pane's
/// bottom edge by `PaneModel.setFindBarVisible(_:)`, rendered on
/// `NSGlassEffectView` so the page beneath stays visible through
/// the Liquid Glass material. Independent of the URL bar —
/// `setFindBarVisible(true)` can fire whether or not the URL bar
/// is currently revealed.
///
/// An earlier in-window revision wrapped the bar in
/// `NSGlassEffectView` directly and was reverted because the
/// backdrop layer's lazy first-paint produced a one-frame black
/// flash on initial reveal. The child-panel architecture sidesteps
/// that path: panel + glass are created once, kept alive across
/// show/hide cycles, and only the panel's alpha animates — the
/// backdrop attaches once and survives every subsequent toggle.
@MainActor
public final class FindBarView: NSView, NSTextFieldDelegate {
  /// Pill height. Tall enough to read as a discrete overlay rather
  /// than a chrome strip; the URL bar is the latter.
  public static let barHeight: CGFloat = 36

  /// Pill width. Fixed so the layout stays predictable across pane
  /// sizes and so positioning logic in `PaneModel` can compute the
  /// panel rect without measuring intrinsic content.
  public static let barWidth: CGFloat = 380

  /// Pill bottom margin from the anchor view's bottom edge.
  public static let bottomMargin: CGFloat = 16

  /// Reveal / dismiss animation duration. Matches the prior alpha
  /// fade so the visible cadence stays the same.
  private static let fadeDuration: TimeInterval = 0.12

  private let searchField = NSTextField()
  private let matchCountLabel = NSTextField(labelWithString: "")
  private let prevButton: HoverIconButton
  private let nextButton: HoverIconButton
  private let closeButton: HoverIconButton
  private let glass = NSGlassEffectView()
  private var cornerObserver: SurfaceCornerObserver?
  /// Wrapper that fills `glass.contentView` so the fixed-size card
  /// can sit inside it at an offset. Required because
  /// `NSGlassEffectView` auto-pins its `contentView` to its bounds —
  /// using `card` directly as `contentView` would force `card` to
  /// resize when the panel clips, defeating the "stay anchored, clip
  /// the overflow" layout the URL bar uses.
  private let inner = NSView()
  private let card = NSView()
  /// Leading constraint that shifts `card` within `inner` so the bar
  /// keeps its natural position relative to the pane while the panel
  /// itself is clipped to the host window. Negative when the bar's
  /// left edge has scrolled past the window's left edge.
  private var cardLeadingConstraint: NSLayoutConstraint?

  private var panel: NSPanel?
  /// Anchor view passed to the most recent `show(anchoredTo:)`. The
  /// scroll and window-resize observers reposition the panel against
  /// this view; it stays in sync with the pane the bar is targeting.
  private weak var anchorView: NSView?

  /// Observer for the workspace clipView's bounds change. Re-runs
  /// `repositionPanel` so the panel follows the pane as the user
  /// scrolls panes horizontally. `nonisolated(unsafe)` so `deinit`
  /// can release the token under Swift 6 strict concurrency.
  nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?

  /// Observer for the parent window's resize notification.
  /// Same nonisolated rationale as `scrollObserver`.
  nonisolated(unsafe) private var parentResizeObserver: NSObjectProtocol?

  /// Observer for the find panel's `didBecomeKeyNotification`. Fires
  /// `onPanelBecameKey` so the host can chase pane focus when the
  /// user clicks a non-focused pane's bar.
  nonisolated(unsafe) private var panelKeyObserver: NSObjectProtocol?

  /// Generation counter that gates the hide animation's completion
  /// handler against a `show` that arrives mid-fade. Without it, an
  /// in-flight hide tween's completion would still call `orderOut`
  /// after `show` fired the next reveal, blanking out a bar the user
  /// just summoned.
  private var hideGeneration = 0

  /// Last `current` value we displayed that was strictly positive.
  /// Retained so that a `current = 0` return from the position query
  /// (typical when the live find selection sits in a cross-origin
  /// iframe whose DOM we can't walk) doesn't slam the label back to
  /// zero as the user pages through. Reset on needle change and
  /// explicit hide.
  private var lastKnownCurrent: Int?

  /// Whether the bar exposes ↑ / ↓ stepping. `true` for browser /
  /// terminal find (the user walks through matches), `false` for
  /// finder-pane filter (the visible rows *are* the result, no
  /// stepping is meaningful). When false the position label shows
  /// `"N items"` instead of `"current / total"`.
  private var stepping: Bool = true

  /// Called whenever the search field's text changes. Empty strings are
  /// forwarded so the helper can end the current session.
  public var onSearch: ((String) -> Void)?
  /// Called on "next match" (⌘G, Return in the field, or the `↓` button).
  public var onNext: (() -> Void)?
  /// Called on "previous match" (⌘⇧G, Shift+Return, or the `↑` button).
  public var onPrev: (() -> Void)?
  /// Called when the user dismisses the bar (Esc, `×` button, or the
  /// container closing it due to focus / sidebar interaction).
  public var onClose: (() -> Void)?
  /// Fired when the bar's panel becomes key — typically because the
  /// user clicked into the search field or one of the buttons. The
  /// host uses this to move pane focus to the bar's owning pane so
  /// interacting with a non-focused pane's bar visibly elevates it
  /// (the user clicked there, after all).
  public var onPanelBecameKey: (() -> Void)?

  public override init(frame: NSRect) {
    prevButton = Self.makeIconButton(
      symbol: "chevron.up",
      fallback: "\u{25B2}",
      accessibility: "Previous match"
    )
    nextButton = Self.makeIconButton(
      symbol: "chevron.down",
      fallback: "\u{25BC}",
      accessibility: "Next match"
    )
    closeButton = Self.makeIconButton(
      symbol: "xmark",
      fallback: "\u{2715}",
      accessibility: "Close find bar"
    )

    super.init(frame: frame)
    appearance = NSAppearance(named: .darkAqua)
    setupGlass()
    setupField()
    setupMatchCountLabel()
    setupButtons()
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  deinit {
    if let token = scrollObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = parentResizeObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = panelKeyObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  // MARK: - Glass surface

  private func setupGlass() {
    glass.translatesAutoresizingMaskIntoConstraints = false
    inner.translatesAutoresizingMaskIntoConstraints = false
    card.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView = inner
    glass.layer?.cornerCurve = .continuous
    glass.layer?.masksToBounds = true
    cornerObserver = SurfaceCornerObserver(applyingTo: glass)
    addSubview(glass)
    inner.addSubview(card)
    let cardLeading = card.leadingAnchor.constraint(
      equalTo: inner.leadingAnchor, constant: 0)
    cardLeadingConstraint = cardLeading
    NSLayoutConstraint.activate([
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      cardLeading,
      card.topAnchor.constraint(equalTo: inner.topAnchor),
      card.widthAnchor.constraint(equalToConstant: Self.barWidth),
      card.heightAnchor.constraint(equalToConstant: Self.barHeight),
    ])
  }

  // MARK: - Icon Button Factory

  private static let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)

  private static func makeIconButton(
    symbol: String,
    fallback: String,
    accessibility: String
  ) -> HoverIconButton {
    let button = HoverIconButton()
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = .systemFont(ofSize: 10)
    button.translatesAutoresizingMaskIntoConstraints = false
    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
      .withSymbolConfiguration(iconConfig)
    {
      button.image = image
      button.imagePosition = .imageOnly
    } else {
      button.title = fallback
    }
    // `accessibilityDescription` on the SF Symbol only propagates
    // when the image resolves. Set the label explicitly so VoiceOver
    // still reads a meaningful name on the fallback glyph path.
    button.setAccessibilityLabel(accessibility)
    return button
  }

  // MARK: - Setup

  private func setupField() {
    searchField.placeholderString = "Find in page…"
    searchField.font = Self.searchFont
    searchField.delegate = self
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.focusRingType = .none
    searchField.cell?.isScrollable = true
    searchField.cell?.usesSingleLineMode = true
    searchField.cell?.lineBreakMode = .byClipping
    searchField.isBezeled = false
    searchField.drawsBackground = false
    searchField.textColor = .labelColor
    card.addSubview(searchField)
  }

  /// Font driving the search field's intrinsic height.
  private static let searchFont = NSFont.systemFont(ofSize: 12)

  /// Tight height that matches the font's bounding rect plus a single
  /// pixel of breathing room. Sizing the field to its line height
  /// makes cell rect ≈ text rect, so AppKit's choice of top-align vs
  /// center-align inside the cell becomes invisible — there's no
  /// vertical space left over to misplace the glyphs in.
  private static let searchFieldHeight: CGFloat = ceil(searchFont.boundingRectForFont.height) + 1

  private func setupMatchCountLabel() {
    matchCountLabel.font = .systemFont(ofSize: 11)
    matchCountLabel.textColor = .secondaryLabelColor
    matchCountLabel.drawsBackground = false
    matchCountLabel.isBezeled = false
    matchCountLabel.isEditable = false
    matchCountLabel.isSelectable = false
    matchCountLabel.alignment = .right
    matchCountLabel.isHidden = true
    matchCountLabel.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(matchCountLabel)
  }

  private func setupButtons() {
    prevButton.target = self
    prevButton.action = #selector(prevAction)
    prevButton.toolTip = "Previous match (⌘⇧G)"
    nextButton.target = self
    nextButton.action = #selector(nextAction)
    nextButton.toolTip = "Next match (⌘G)"
    closeButton.target = self
    closeButton.action = #selector(closeAction)
    closeButton.toolTip = "Close (Esc)"

    card.addSubview(prevButton)
    card.addSubview(nextButton)
    card.addSubview(closeButton)
  }

  private func setupLayout() {
    let buttonSize: CGFloat = 22
    NSLayoutConstraint.activate([
      // Close × on the leading edge follows macOS Safari / Firefox-on-mac
      // convention for find bars: dismiss is the most predictable
      // gesture and lives where the user expects it on this platform.
      closeButton.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
      closeButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
      closeButton.heightAnchor.constraint(equalToConstant: buttonSize),

      searchField.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
      searchField.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      searchField.heightAnchor.constraint(equalToConstant: Self.searchFieldHeight),
      // searchField → matchCountLabel → prevButton → nextButton.
      // When the count label is hidden its intrinsic size collapses
      // to zero, so the searchField effectively extends up to the
      // prev button.
      searchField.trailingAnchor.constraint(equalTo: matchCountLabel.leadingAnchor, constant: -4),

      matchCountLabel.trailingAnchor.constraint(equalTo: prevButton.leadingAnchor, constant: -4),
      matchCountLabel.centerYAnchor.constraint(equalTo: card.centerYAnchor),

      prevButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      prevButton.widthAnchor.constraint(equalToConstant: buttonSize),
      prevButton.heightAnchor.constraint(equalToConstant: buttonSize),

      nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
      nextButton.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
      nextButton.centerYAnchor.constraint(equalTo: card.centerYAnchor),
      nextButton.widthAnchor.constraint(equalToConstant: buttonSize),
      nextButton.heightAnchor.constraint(equalToConstant: buttonSize),
    ])
  }

  // MARK: - Public API

  /// Current text in the search field. Setting updates the field without
  /// firing `onSearch` (the setter does not go through
  /// `NSTextFieldDelegate`); callers are expected to drive the find
  /// session themselves when pre-filling.
  public var searchText: String {
    get { searchField.stringValue }
    set { searchField.stringValue = newValue }
  }

  /// Move first responder to the search field and select its contents
  /// so the typical "type to replace, shift-arrow to extend" flow works.
  /// `makeKey` is required alongside `makeFirstResponder` because a
  /// click on the page beneath leaves the panel visible but resigned
  /// from key state — without re-keying, ⌘F would re-enter
  /// `openFindBar` but the field would never receive keystrokes
  /// (typing falls through to whichever responder owns the main
  /// window).
  public func focusField() {
    guard let panel else { return }
    if !panel.isKeyWindow { panel.makeKey() }
    panel.makeFirstResponder(searchField)
    searchField.selectText(nil)
  }

  /// Toggle the ↑ / ↓ stepping affordance and the position label's
  /// formatting. Set to `false` for finder-pane filter mode where
  /// stepping has no meaning — the visible rows *are* the result —
  /// and the `"N items"` label communicates the hit count without
  /// implying navigable matches.
  public func setSteppingEnabled(_ enabled: Bool) {
    stepping = enabled
    prevButton.isHidden = !enabled
    nextButton.isHidden = !enabled
    // The placeholder text doubles as a hint for what the bar does;
    // "Find in page" reads odd when the bar drives a row filter.
    searchField.placeholderString = enabled ? "Find in page…" : "Filter…"
  }

  /// Update the match-position indicator displayed to the right of
  /// the search field. Passing `nil` for either side hides the label
  /// and restores the default tint. Passing `(current: 0, total: 0)`
  /// reveals "0 / 0" and tints the search field red to flag a
  /// no-match state; any positive `total` shows "current / total" in
  /// the neutral tint and matches Brave / Chrome / Firefox conventions.
  ///
  /// When `current = 0` but `total > 0` we interpret it as "the JS
  /// walker couldn't locate the live selection" — typically because
  /// the selection is in a cross-origin iframe. In that case the
  /// last known non-zero current is displayed instead so the label
  /// stays on the user's previous hit instead of snapping to zero.
  public func setMatchPosition(current: Int?, total: Int?) {
    guard let current, let total else {
      matchCountLabel.stringValue = ""
      matchCountLabel.isHidden = true
      searchField.textColor = .labelColor
      lastKnownCurrent = nil
      return
    }
    if !stepping {
      // Filter mode — render a plain count instead of the
      // `current / total` form that implies stepping. `current` is
      // ignored: every row in the filtered list is "active".
      matchCountLabel.stringValue = total == 1 ? "1 item" : "\(total) items"
      matchCountLabel.isHidden = false
      searchField.textColor = total > 0 ? .labelColor : .systemRed
      return
    }
    let displayCurrent: Int
    if current == 0, total > 0, let last = lastKnownCurrent {
      displayCurrent = last
    } else {
      displayCurrent = current
      if current > 0 {
        lastKnownCurrent = current
      } else if total == 0 {
        lastKnownCurrent = nil
      }
    }
    matchCountLabel.stringValue = "\(displayCurrent) / \(total)"
    matchCountLabel.isHidden = false
    searchField.textColor = total > 0 ? .labelColor : .systemRed
  }

  // MARK: - Testing Support

  /// Current text of the match-count label. Exposed so tests can
  /// verify `setMatchCount`'s branching without reaching through the
  /// view hierarchy.
  var matchCountText: String {
    matchCountLabel.stringValue
  }

  // MARK: - Panel lifecycle

  /// Show the panel anchored to `view`'s bottom edge and fade it in.
  /// Idempotent — repeat shows reuse the existing panel and just
  /// re-run the layout against the (possibly new) anchor.
  public func show(anchoredTo view: NSView) {
    guard let parentWindow = view.window else { return }
    let panel = ensurePanel(parentWindow: parentWindow)
    // Bump the generation so any in-flight hide tween's completion
    // handler is invalidated and won't orderOut the panel we're
    // about to reveal.
    hideGeneration += 1
    anchorView = view
    bindWorkspaceObservers(parent: parentWindow, anchor: view)
    repositionPanel()

    // Always reset model alpha to 0 before the fade-in animation,
    // regardless of `panel.isVisible`. The previous "only reset when
    // not visible" branch trusted the hide-tween completion to leave
    // the model at 0 — but a system event that invalidates the layer
    // mid-fade (display sleep, fullscreen transition, Liquid Glass
    // material refresh) can leave the panel ordered front at alpha 0
    // (key dispatch works, the bar is invisible) and the next show's
    // animator never commits a fresh interpolation. The unconditional
    // reset costs one extra frame of "snap to 0" on the rare
    // interrupted-show path but guarantees the fade-in starts from a
    // known model value. The `< 1` gate keeps the normal path silent
    // and only routes the recovery case through the log.
    if panel.isVisible, panel.alphaValue < 1 {
      logPopupAlphaRecovery(panel: panel, scope: "findbar")
    }
    panel.alphaValue = 0
    panel.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fadeDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 1
    }
  }

  /// Fade the panel out and order it out at the end of the tween.
  /// Safe to call when the bar was never shown.
  public func hide() {
    guard let panel, panel.isVisible else { return }
    hideGeneration += 1
    let myGeneration = hideGeneration
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = Self.fadeDuration
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 0
    }, completionHandler: { [weak self] in
      // A `show` arriving mid-fade bumps the generation; bail when
      // ours doesn't match so we don't blank out the just-revealed
      // panel.
      guard let self, self.hideGeneration == myGeneration else { return }
      self.panel?.orderOut(nil)
    })
    if let token = scrollObserver {
      NotificationCenter.default.removeObserver(token)
      scrollObserver = nil
    }
    if let token = parentResizeObserver {
      NotificationCenter.default.removeObserver(token)
      parentResizeObserver = nil
    }
    anchorView = nil
  }

  /// Build (or reattach) the find panel. Reparent guard mirrors
  /// `PaneURLBar.ensureSuggestionPanel` — dead in the single-window
  /// invariant, cheap insurance for a future multi-window split.
  private func ensurePanel(parentWindow: NSWindow) -> NSPanel {
    if let existing = panel {
      if existing.parent !== parentWindow {
        existing.parent?.removeChildWindow(existing)
        parentWindow.addChildWindow(existing, ordered: .above)
      }
      return existing
    }
    let p = FindBarPanel(
      contentRect: .zero,
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    p.contentView = self
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .popUpMenu
    // The find bar is a "session" overlay — Cmd+Tabbing to another
    // app and coming back should leave the search state intact, the
    // way Safari's find bar does. URL bar dropdown / command palette
    // use `hidesOnDeactivate = true` because they're transient
    // pickers; the find bar is closer to a sticky inspector.
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.transient, .ignoresCycle]
    p.isReleasedWhenClosed = false
    parentWindow.addChildWindow(p, ordered: .above)
    panel = p
    panelKeyObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification,
      object: p,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onPanelBecameKey?() }
    }
    return p
  }

  /// Subscribe to the workspace clipView's bounds change and the
  /// parent window's resize so the panel re-anchors as the pane
  /// moves. Mirrors `PaneURLBar.viewDidMoveToWindow` setup.
  private func bindWorkspaceObservers(parent: NSWindow, anchor: NSView) {
    if let token = scrollObserver {
      NotificationCenter.default.removeObserver(token)
      scrollObserver = nil
    }
    if let token = parentResizeObserver {
      NotificationCenter.default.removeObserver(token)
      parentResizeObserver = nil
    }
    if let clipView = anchor.enclosingScrollView?.contentView {
      clipView.postsBoundsChangedNotifications = true
      scrollObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.repositionPanel() }
      }
    } else {
      // No scroll view in the anchor's superview chain — workspace
      // horizontal scrolls won't trigger reposition. Logged rather
      // than silently dropped so a future host that bypasses the
      // workspace scroll machinery surfaces this loss.
      logger.info("scroll-tracking disabled: anchor has no enclosing scrollView")
    }
    parentResizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification,
      object: parent,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.repositionPanel() }
    }
  }

  /// Place the panel at the bar's natural anchor position
  /// (centered on the pane's full width, fixed 380×36) and clip it
  /// to the host window's visible frame. The card inside the panel
  /// keeps its full barWidth and shifts via `cardLeadingConstraint`
  /// so the visible portion of the bar stays in lockstep with the
  /// pane — matching the URL bar dropdown's "anchored content,
  /// clipped chrome" behaviour rather than shrinking the bar's
  /// internal layout to fit. Orders out when the visible slice
  /// drops below a readable threshold; re-orders front
  /// automatically once the pane scrolls back into view.
  private func repositionPanel() {
    guard let panel, let anchor = anchorView,
      let parent = anchor.window
    else { return }
    let anchorInWindow = anchor.convert(anchor.bounds, to: nil)
    let anchorOnScreen = parent.convertToScreen(anchorInWindow)

    let windowFrame = parent.frame
    let naturalLeft = anchorOnScreen.midX - Self.barWidth / 2
    let naturalRight = naturalLeft + Self.barWidth
    let clippedLeft = max(naturalLeft, windowFrame.minX)
    let clippedRight = min(naturalRight, windowFrame.maxX)
    let clippedWidth = clippedRight - clippedLeft

    let minVisibleWidth: CGFloat = 80
    if clippedWidth < minVisibleWidth {
      if panel.isVisible { panel.orderOut(nil) }
      return
    }

    // Shift the card within the panel so the same content stays
    // anchored to the pane regardless of how the panel itself was
    // clipped against the window edge. A negative offset means the
    // bar's left edge has scrolled past the window's left and the
    // card extends behind it (clipped by `glass.masksToBounds`).
    cardLeadingConstraint?.constant = naturalLeft - clippedLeft

    // Screen Y is bottom-up: `anchorOnScreen.minY` is the anchor's
    // bottom edge in screen space, so `+ bottomMargin` lifts the
    // panel's bottom edge `bottomMargin` points above the anchor's
    // bottom — leaving a `bottomMargin`-tall gap between the bar
    // and the pane's bottom edge.
    let panelFrame = NSRect(
      x: clippedLeft,
      y: anchorOnScreen.minY + Self.bottomMargin,
      width: clippedWidth,
      height: Self.barHeight
    )
    panel.setFrame(panelFrame, display: true)
    if !panel.isVisible { panel.orderFront(nil) }
  }

  // MARK: - Button Actions

  @objc private func prevAction() { onPrev?() }
  @objc private func nextAction() { onNext?() }
  @objc private func closeAction() { onClose?() }

  // MARK: - NSTextFieldDelegate

  public func controlTextDidChange(_: Notification) {
    // A new needle invalidates any retained position — drop it now
    // so the first query for the new search can report an honest
    // zero without the fallback fishing out a stale prior value.
    lastKnownCurrent = nil
    onSearch?(searchField.stringValue)
  }

  public func control(
    _: NSControl,
    textView _: NSTextView,
    doCommandBy selector: Selector
  ) -> Bool {
    if selector == #selector(insertNewline(_:)) {
      // NSTextField's field editor normalises Shift+Return into
      // `insertNewline:` carrying a `.shift` modifier — following the
      // rewrite that StandardKeyBinding.dict applies for single-line
      // controls (QA1454). Peek the current event to pick the
      // navigation direction accordingly.
      let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
      (shift ? onPrev : onNext)?()
      return true
    }
    // Belt-and-braces: if a custom key binding dict or a future AppKit
    // change starts routing Shift+Return through `insertLineBreak:`
    // directly, still reach the previous-match path.
    if selector == #selector(insertLineBreak(_:)) {
      onPrev?()
      return true
    }
    if selector == #selector(cancelOperation(_:)) {
      onClose?()
      return true
    }
    // Eat Tab / Shift+Tab so AppKit's default `insertTab:` →
    // `nextKeyView` walk doesn't jump first responder out of the
    // search field and into the pane content (in a multi-pane
    // window, that lands focus on the neighbouring pane and the
    // user reads it as "Tab moved to the next pane"). Ctrl+Tab is
    // separately bound at the menu-key-equivalent layer to
    // `focusNextPane` and reaches the action handler before this
    // delegate sees it, so explicit pane navigation still works.
    if selector == #selector(insertTab(_:))
      || selector == #selector(insertBacktab(_:))
    {
      return true
    }
    return false
  }
}

/// Borderless panel that opts into key-window status. The default for
/// a borderless NSPanel is `canBecomeKey = false`, which would block
/// keyboard input to the search field. Same shape as
/// `CommandPalettePanel`.
private final class FindBarPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
