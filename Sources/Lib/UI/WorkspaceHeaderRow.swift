import AppKit

/// One row in the sidebar worklane section representing a workspace.
/// Shows a 3pt vertical color indicator (position-based accent) + the
/// workspace name. The current workspace is rendered bold with
/// full-alpha indicator, others in 0.6 alpha for visual de-emphasis.
/// Clicking fires `onClick` which the sidebar routes to
/// `PaneContainerViewController.switchWorkspace(to:)`. The hover-
/// revealed × button fires `onClose`, which routes to
/// `PaneContainerViewController.closeWorkspace(at:)`.
@MainActor
final class WorkspaceHeaderRow: NSView {
  static let height: CGFloat = 28

  let workspaceIndex: Int
  var onClick: (() -> Void)?
  var onClose: (() -> Void)?

  private let indicator = NSView()
  private let label = NSTextField(labelWithString: "")
  private let closeButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close workspace")
    b.toolTip = "Close workspace"
    b.isHidden = true
    return b
  }()
  private var trackingArea: NSTrackingArea?
  private var isHovered = false

  init(index: Int, title: String, accentColor: NSColor, isCurrent: Bool) {
    self.workspaceIndex = index
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
    configure(title: title, accentColor: accentColor, isCurrent: isCurrent)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    indicator.translatesAutoresizingMaskIntoConstraints = false
    indicator.wantsLayer = true
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.drawsBackground = false
    closeButton.target = self
    closeButton.action = #selector(closeTapped(_:))
    addSubview(indicator)
    addSubview(label)
    addSubview(closeButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),

      indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      indicator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      indicator.widthAnchor.constraint(equalToConstant: 3),

      label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 10),
      label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 18),
      closeButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  private func configure(title: String, accentColor: NSColor, isCurrent: Bool) {
    label.stringValue = title
    label.font = isCurrent ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
    label.alphaValue = isCurrent ? 1.0 : 0.6
    indicator.layer?.backgroundColor =
      isCurrent
      ? accentColor.cgColor
      : accentColor.withAlphaComponent(0.6).cgColor
    indicator.layer?.cornerRadius = 1.5
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
