import AppKit

/// Bottom navigation strip in the sidebar. Lays one icon-only button
/// per `SidebarMode` (Tabs / Bookmarks / History / Downloads /
/// Extensions) into a single equal-width row. Clicking a button
/// invokes `onSelect`, which the sidebar view controller uses to
/// swap the mode area's content. The Downloads button exposes a
/// pill-shaped active-count badge overlaid on the icon's top-right
/// corner; the badge is hidden when the count is zero.
///
/// Labels live as `toolTip` and accessibility values rather than as
/// inline text so the strip stays compact enough to free vertical
/// space for the worklane and bookmarks/history lists above.
@MainActor
final class PlacesSectionView: NSView {
  /// Fired when the user selects a mode by clicking its button.
  var onSelect: ((SidebarMode) -> Void)?

  private let stack = NSStackView()
  private var buttons: [SidebarMode: PlacesButton] = [:]

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    stack.orientation = .horizontal
    // 4 px spacing leaves a comfortable gutter between buttons even
    // when several modes are highlighted in transition; the equal
    // distribution keeps the row symmetric as `SidebarMode` grows.
    stack.spacing = 4
    stack.alignment = .centerY
    stack.distribution = .fillEqually
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: PlacesButton.height),
    ])
    for mode in SidebarMode.allCases {
      let button = PlacesButton(mode: mode)
      button.onClick = { [weak self] in self?.onSelect?(mode) }
      stack.addArrangedSubview(button)
      buttons[mode] = button
    }
  }

  /// Highlight the current mode's button; clear the others.
  func setCurrentMode(_ mode: SidebarMode) {
    for (buttonMode, button) in buttons {
      button.setSelected(buttonMode == mode)
    }
  }

  /// Update the Downloads button badge. A count of zero hides the badge.
  func setDownloadsBadge(count: Int) {
    buttons[.downloads]?.setBadge(count: count)
  }

  // Absorb mouse events that land in the gutters between buttons (and
  // in the strip's padding). Without these overrides the click would
  // forward up the responder chain via the `NSResponder` default and
  // leak through `NSGlassEffectView`'s transparent regions to the
  // workspace pane underneath, letting the user click links / select
  // text in the WebView through the sidebar's footer area. Same
  // pattern as `FlippedClipView` in the worklane — `scrollWheel` etc.
  // are intentionally not overridden.
  override func mouseDown(with _: NSEvent) {}
  override func mouseDragged(with _: NSEvent) {}
  override func mouseUp(with _: NSEvent) {}
}

/// One clickable button in `PlacesSectionView`: an icon centered in
/// a tappable square, optionally overlaid with a notification-style
/// badge (used only by the Downloads button). The mode label is
/// surfaced via `toolTip` and `accessibilityLabel` rather than as
/// inline text so the strip can fit five modes inside the sidebar's
/// 260pt width.
@MainActor
private final class PlacesButton: NSView {
  /// Fixed strip height. Combined with `.fillEqually` distribution
  /// in the parent stack, every button ends up the same square-ish
  /// hit target across the row.
  static let height: CGFloat = 36

  let mode: SidebarMode
  var onClick: (() -> Void)?

  private let iconView = NSImageView()
  private let badge = DownloadsBadgeView()
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isSelected = false

  init(mode: SidebarMode) {
    self.mode = mode
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    toolTip = mode.title
    setAccessibilityRole(.button)
    setAccessibilityLabel(mode.title)
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let old = trackingArea { removeTrackingArea(old) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with _: NSEvent) {
    isHovered = true
    applyBackground()
  }

  override func mouseExited(with _: NSEvent) {
    isHovered = false
    applyBackground()
  }

  private func setupLayout() {
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = NSImage(
      systemSymbolName: mode.symbolName,
      accessibilityDescription: mode.title
    )
    iconView.imageScaling = .scaleProportionallyDown
    iconView.contentTintColor = .secondaryLabelColor
    addSubview(iconView)

    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.isHidden = true
    addSubview(badge)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),
      // Pin the badge to the icon's top-right corner with a small
      // overlap so it reads as "attached" to the icon rather than
      // floating in the gutter, matching macOS Mail's unread badge.
      badge.centerXAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
      badge.centerYAnchor.constraint(equalTo: iconView.topAnchor, constant: 2),
    ])
  }

  func setSelected(_ selected: Bool) {
    isSelected = selected
    iconView.contentTintColor = selected ? .labelColor : .secondaryLabelColor
    applyBackground()
  }

  /// Resolve `layer.backgroundColor` from the current selection +
  /// hover state. Selected buttons take a stronger tint than a passive
  /// hover so the active mode keeps reading as active even while the
  /// pointer roams over its neighbours. Subtle white tints carry over
  /// from the previous design — they read in both light and dark
  /// appearances against the sidebar's Liquid Glass background.
  private func applyBackground() {
    let alpha: CGFloat
    switch (isSelected, isHovered) {
    case (true, _): alpha = 0.15
    case (false, true): alpha = 0.08
    case (false, false): alpha = 0
    }
    layer?.backgroundColor =
      alpha > 0 ? NSColor(white: 1.0, alpha: alpha).cgColor : nil
    layer?.cornerRadius = alpha > 0 ? 6 : 0
  }

  func setBadge(count: Int) {
    if count <= 0 {
      badge.isHidden = true
    } else {
      badge.count = count
      badge.isHidden = false
    }
  }

  override func mouseDown(with _: NSEvent) {
    onClick?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

/// Mail.app-style pill badge showing a numeric count, sized to ride
/// on top of the 18 × 18 mode icon without obscuring it. Height is
/// fixed so the corner radius can form a perfect pill; width grows
/// with the label (min-width equals height for single-digit counts).
/// The accent fill stays opaque so the badge stays legible against
/// either a sidebar gutter or the icon's own contentTintColor.
@MainActor
private final class DownloadsBadgeView: NSView {
  static let height: CGFloat = 13

  var count: Int = 0 {
    didSet { label.stringValue = count > 99 ? "99+" : "\(count)" }
  }

  private let label = NSTextField(labelWithString: "0")

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.systemBlue.cgColor
    layer?.cornerRadius = Self.height / 2
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    label.translatesAutoresizingMaskIntoConstraints = false
    // Monospaced digits keep the pill width stable as the count
    // changes (1 → 10 → 99+) without snap-resizing on every tick.
    label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    label.textColor = .white
    label.drawsBackground = false
    label.alignment = .center
    addSubview(label)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      widthAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
    ])
  }
}
