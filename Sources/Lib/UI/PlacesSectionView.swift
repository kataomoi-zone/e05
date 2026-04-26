import AppKit

/// Bottom navigation strip in the sidebar. Arranges one row per
/// `SidebarMode` (Tabs / Bookmarks / History / Downloads). Clicking a
/// row invokes `onSelect`, which the sidebar view controller uses to
/// swap the mode area's content. The Downloads row exposes a pill-
/// shaped active-count badge that's hidden when the count is zero.
@MainActor
final class PlacesSectionView: NSView {
  /// Fired when the user selects a mode by clicking its row.
  var onSelect: ((SidebarMode) -> Void)?

  private let stack = NSStackView()
  private var rows: [SidebarMode: PlacesRow] = [:]

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    stack.orientation = .vertical
    stack.spacing = 2
    stack.alignment = .leading
    stack.distribution = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    for mode in SidebarMode.allCases {
      let row = PlacesRow(mode: mode)
      row.onClick = { [weak self] in self?.onSelect?(mode) }
      stack.addArrangedSubview(row)
      NSLayoutConstraint.activate([
        row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
      ])
      rows[mode] = row
    }
  }

  /// Highlight the current mode's row; clear the others.
  func setCurrentMode(_ mode: SidebarMode) {
    for (rowMode, row) in rows {
      row.setSelected(rowMode == mode)
    }
  }

  /// Update the Downloads row badge. A count of zero hides the badge.
  func setDownloadsBadge(count: Int) {
    rows[.downloads]?.setBadge(count: count)
  }

  // Absorb mouse events that land on the 2pt gaps between the four
  // mode rows (and on any padding around the stack). Without these
  // overrides the click would forward up the responder chain via the
  // `NSResponder` default and leak through `NSGlassEffectView`'s
  // transparent regions to the workspace pane underneath, letting the
  // user click links / select text in the WebView through the
  // sidebar's footer area. Same pattern as `FlippedClipView` in the
  // worklane — `scrollWheel` etc. are intentionally not overridden.
  override func mouseDown(with _: NSEvent) {}
  override func mouseDragged(with _: NSEvent) {}
  override func mouseUp(with _: NSEvent) {}
}

/// One clickable row in `PlacesSectionView`: icon + label, with an
/// optional trailing badge (used only by the Downloads row).
@MainActor
private final class PlacesRow: NSView {
  static let height: CGFloat = 28

  let mode: SidebarMode
  var onClick: (() -> Void)?

  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let badge = DownloadsBadgeView()
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isSelected = false

  init(mode: SidebarMode) {
    self.mode = mode
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
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

    label.translatesAutoresizingMaskIntoConstraints = false
    label.stringValue = mode.title
    label.font = .systemFont(ofSize: 13)
    label.textColor = .labelColor
    label.drawsBackground = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    addSubview(label)

    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.isHidden = true
    addSubview(badge)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 16),
      iconView.heightAnchor.constraint(equalToConstant: 16),
      label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
      badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      badge.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  func setSelected(_ selected: Bool) {
    isSelected = selected
    iconView.contentTintColor = selected ? .labelColor : .secondaryLabelColor
    label.font = selected
      ? .systemFont(ofSize: 13, weight: .semibold)
      : .systemFont(ofSize: 13)
    applyBackground()
  }

  /// Resolve `layer.backgroundColor` from the current selection +
  /// hover state. Selected rows take a stronger tint than a passive
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
    layer?.cornerRadius = alpha > 0 ? 4 : 0
  }

  func setBadge(count: Int) {
    if count <= 0 {
      badge.isHidden = true
    } else {
      badge.count = count
      badge.isHidden = false
    }
  }

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

/// Mail.app-style pill badge showing a numeric count. Height is fixed
/// so the corner radius can form a perfect pill; width grows with the
/// label (min-width equals height for single-digit counts).
@MainActor
private final class DownloadsBadgeView: NSView {
  static let height: CGFloat = 16

  var count: Int = 0 {
    didSet { label.stringValue = "\(count)" }
  }

  private let label = NSTextField(labelWithString: "0")

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.25).cgColor
    layer?.cornerRadius = Self.height / 2
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    label.translatesAutoresizingMaskIntoConstraints = false
    // Monospaced digits keep the pill width stable as the count
    // changes (1 → 10 → 100) without snap-resizing on every tick.
    label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    label.textColor = .labelColor
    label.drawsBackground = false
    label.alignment = .center
    addSubview(label)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      widthAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
    ])
  }
}
