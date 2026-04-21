import AppKit

/// Overlay shown above a focused pane for incremental find-in-page.
///
/// The container (`PaneContainerViewController`) manages the outer
/// frame — this view is installed as a manual-frame subview of the
/// window content view and repositioned whenever the focused pane
/// changes. Height matches `PaneURLBar.barHeight` so the two sit on
/// the same baseline when the URL bar is visible.
@MainActor
public final class FindBarView: NSView, NSTextFieldDelegate {
  public static let barHeight: CGFloat = PaneURLBar.barHeight

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
    layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor

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
    searchField.placeholderString = "Find in page..."
    searchField.font = .systemFont(ofSize: 12)
    searchField.delegate = self
    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.focusRingType = .none
    searchField.cell?.isScrollable = true
    searchField.isBezeled = false
    searchField.drawsBackground = true
    searchField.backgroundColor = NSColor(white: 0.18, alpha: 1.0)
    searchField.textColor = .labelColor
    addSubview(searchField)
  }

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
      searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
      searchField.heightAnchor.constraint(equalToConstant: 22),
      // searchField → matchCountLabel → prevButton. When the count
      // label is hidden its intrinsic size collapses to zero, so the
      // searchField effectively extends up to the prev button.
      searchField.trailingAnchor.constraint(equalTo: matchCountLabel.leadingAnchor, constant: -4),

      matchCountLabel.trailingAnchor.constraint(equalTo: prevButton.leadingAnchor, constant: -4),
      matchCountLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      prevButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      prevButton.widthAnchor.constraint(equalToConstant: buttonSize),
      prevButton.heightAnchor.constraint(equalToConstant: buttonSize),

      nextButton.leadingAnchor.constraint(equalTo: prevButton.trailingAnchor, constant: 2),
      nextButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      nextButton.widthAnchor.constraint(equalToConstant: buttonSize),
      nextButton.heightAnchor.constraint(equalToConstant: buttonSize),

      closeButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 2),
      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: buttonSize),
      closeButton.heightAnchor.constraint(equalToConstant: buttonSize),
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
    return false
  }
}
