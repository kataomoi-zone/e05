import AppKit

/// Floating pill shown over the focused pane for incremental
/// find-in-page. Anchored to the pane's bottom edge by `PaneModel`,
/// rendered as a translucent dark surface so the page beneath stays
/// visible. Independent of the URL bar — `setFindBarVisible(true)`
/// can fire whether or not the URL bar is currently revealed.
///
/// An earlier revision wrapped the bar in `NSGlassEffectView` for
/// Liquid Glass blur, but that caused a one-frame black flash on the
/// very first reveal (the glass's backdrop layer is built lazily on
/// first paint) and a brief "completion-popup-shaped" black square
/// below the bar from the same lazy-attach window. The transient
/// nature of the find bar made the trade-off lopsided: the visual
/// payoff of glass was small, and the launch-time artefacts were
/// distracting. The bar is now a plain layer-backed view with a
/// translucent fill — same squircle shape, same close-×-leading
/// layout, just rendered with a single CALayer fill instead of a
/// blurred backdrop.
@MainActor
public final class FindBarView: NSView, NSTextFieldDelegate {
  /// Pill height. Tall enough to read as a discrete overlay rather
  /// than a chrome strip; the URL bar is the latter.
  public static let barHeight: CGFloat = 36

  private let searchField = NSTextField()
  private let matchCountLabel = NSTextField(labelWithString: "")
  private let prevButton: HoverIconButton
  private let nextButton: HoverIconButton
  private let closeButton: HoverIconButton

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
    wantsLayer = true
    appearance = NSAppearance(named: .darkAqua)
    layer?.backgroundColor = AppColors.findBarSurface.cgColor
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = 0.5
    layer?.borderColor = AppColors.findBarBorder.cgColor

    setupField()
    setupMatchCountLabel()
    setupButtons()
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
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
    addSubview(searchField)
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
    addSubview(matchCountLabel)
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

    addSubview(prevButton)
    addSubview(nextButton)
    addSubview(closeButton)
  }

  private func setupLayout() {
    let buttonSize: CGFloat = 22
    NSLayoutConstraint.activate([
      // Close × on the leading edge follows macOS Safari / Firefox-on-mac
      // convention for find bars: dismiss is the most predictable
      // gesture and lives where the user expects it on this platform.
      closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
      closeButton.heightAnchor.constraint(equalToConstant: buttonSize),

      searchField.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
      searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
      searchField.heightAnchor.constraint(equalToConstant: Self.searchFieldHeight),
      // searchField → matchCountLabel → prevButton → nextButton.
      // When the count label is hidden its intrinsic size collapses
      // to zero, so the searchField effectively extends up to the
      // prev button.
      searchField.trailingAnchor.constraint(equalTo: matchCountLabel.leadingAnchor, constant: -4),

      matchCountLabel.trailingAnchor.constraint(equalTo: prevButton.leadingAnchor, constant: -4),
      matchCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      prevButton.widthAnchor.constraint(equalToConstant: buttonSize),
      prevButton.heightAnchor.constraint(equalToConstant: buttonSize),

      nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
      nextButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
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
  public func focusField() {
    window?.makeFirstResponder(searchField)
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

  // MARK: - Button Actions

  @objc private func prevAction() { onPrev?() }
  @objc private func nextAction() { onNext?() }
  @objc private func closeAction() { onClose?() }

  // MARK: - Cursor / event absorption
  //
  // The bar floats over WKWebView / GhosttyTerminalView surfaces.
  // The translucent fill covers the bar's full bounds, but the
  // search field's I-beam cursor rect would otherwise win over the
  // page's text cursor only inside the field's narrow rect — leaving
  // a sliver around the icons where the page-beneath cursor leaks
  // through. Force `arrow` over the whole pill and let child views
  // (search field → I-beam, buttons → pointing hand) override
  // hierarchically. Empty mouse-event overrides ensure clicks on
  // the bar's padding don't fall through to the page's text
  // selection.

  public override func resetCursorRects() {
    addCursorRect(bounds, cursor: .arrow)
  }

  public override func hitTest(_ point: NSPoint) -> NSView? {
    // When the bar is invisible (alpha 0) it must let clicks fall
    // through to the pane content beneath. Without this guard, the
    // mouseDown/Dragged/Up overrides below would absorb every click
    // landing in the bar's permanent 380×36 rect at the pane bottom
    // — turning that strip into a dead zone for link clicks and
    // text selection while no find session is active.
    guard alphaValue > 0.01 else { return nil }
    return super.hitTest(point)
  }

  public override func mouseDown(with _: NSEvent) {}
  public override func mouseDragged(with _: NSEvent) {}
  public override func mouseUp(with _: NSEvent) {}

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
