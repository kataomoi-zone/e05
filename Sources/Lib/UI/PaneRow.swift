import AppKit

/// One row in the sidebar worklane section representing a single pane.
/// Indented under its owning workspace header. The currently focused
/// pane gets a 2pt border in the current workspace's accent color
/// (matching the in-content focus border) so the sidebar mirrors the
/// workspace focus state. Clicking fires `onClick` which the sidebar
/// routes to `PaneContainerViewController.focusPane(id:)` (cross-WS
/// safe via the stage 0-A API). The hover-revealed × button fires
/// `onClose`, which routes to
/// `PaneContainerViewController.closePane(id:)`.
@MainActor
final class PaneRow: NSView {
  static let height: CGFloat = 24
  static let iconSize: CGFloat = 16

  let paneId: ULID
  var onClick: (() -> Void)?
  var onClose: (() -> Void)?

  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let closeButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")
    b.toolTip = "Close pane"
    b.isHidden = true
    return b
  }()
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isCurrentPane = false

  init(paneId: ULID, title: String, icon: NSImage?, accentColor: NSColor, isCurrent: Bool) {
    self.paneId = paneId
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
    configure(title: title, icon: icon, accentColor: accentColor, isCurrent: isCurrent)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.imageFrameStyle = .none
    addSubview(iconView)

    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.drawsBackground = false
    label.font = NSFont.systemFont(ofSize: 12)
    addSubview(label)

    closeButton.target = self
    closeButton.action = #selector(closeTapped(_:))
    addSubview(closeButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      // Favicon / SF-symbol slot sits in the indent that used to be
      // pure whitespace, giving browser and terminal rows a visual
      // identifier without pushing text further right.
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
      label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 16),
      closeButton.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  private func configure(title: String, icon: NSImage?, accentColor: NSColor, isCurrent: Bool) {
    isCurrentPane = isCurrent
    label.stringValue = title
    label.alphaValue = isCurrent ? 1.0 : 0.8
    iconView.image = icon
    iconView.alphaValue = isCurrent ? 1.0 : 0.75
    if isCurrent {
      layer?.borderWidth = 2
      layer?.borderColor = accentColor.cgColor
      layer?.cornerRadius = 4
    } else {
      layer?.borderWidth = 0
      layer?.borderColor = nil
      layer?.cornerRadius = 0
    }
  }

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
    closeButton.isHidden = false
    applyHoverBackground()
  }

  override func mouseExited(with _: NSEvent) {
    isHovered = false
    closeButton.isHidden = true
    applyHoverBackground()
  }

  private func applyHoverBackground() {
    // Skip the hover tint on the focused pane: it already wears a
    // 2pt accent border, and stacking a translucent fill on top of
    // that reads as a state change instead of a hover affordance.
    if isCurrentPane {
      layer?.backgroundColor = nil
      return
    }
    layer?.backgroundColor =
      isHovered ? NSColor(white: 1.0, alpha: 0.08).cgColor : nil
    layer?.cornerRadius = isHovered ? 4 : 0
  }

  override func mouseDown(with _: NSEvent) {
    onClick?()
  }

  @objc private func closeTapped(_: NSButton) {
    onClose?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
