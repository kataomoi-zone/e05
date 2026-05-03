import AppKit

/// One row in the sidebar worklane section representing a workspace.
/// Shows a 3pt vertical color indicator (position-based accent) + the
/// workspace name. The current workspace is rendered bold with
/// full-alpha indicator, others in 0.6 alpha for visual de-emphasis.
/// Clicking fires `onClick` which the sidebar routes to
/// `PaneContainerViewController.switchWorkspace(to:)`. The hover-
/// revealed × button fires `onClose`, which routes to
/// `PaneContainerViewController.closeWorkspace(at:)`. The hover-
/// revealed leading chevron fires `onToggleCollapse`, which the
/// sidebar uses to hide / show this workspace's pane rows in the
/// worklane (UI-only state, not persisted).
@MainActor
final class WorkspaceHeaderRow: NSView {
  static let height: CGFloat = 28

  let workspaceIndex: Int
  var onClick: (() -> Void)?
  var onClose: (() -> Void)?
  var onToggleCollapse: (() -> Void)?

  private let indicator = WorkspaceAccentIndicator()
  private let label = NSTextField(labelWithString: "")
  private let chevronButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.isHidden = true
    return b
  }()
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
  private var isCollapsed = false
  private var accentColor: NSColor = .labelColor

  init(
    index: Int, title: String, accentColor: NSColor,
    isCurrent: Bool, isCollapsed: Bool, isPrivate: Bool
  ) {
    self.workspaceIndex = index
    self.isCollapsed = isCollapsed
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
    configure(
      title: title, accentColor: accentColor, isCurrent: isCurrent,
      isPrivate: isPrivate)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    indicator.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.drawsBackground = false
    chevronButton.target = self
    chevronButton.action = #selector(chevronTapped(_:))
    closeButton.target = self
    closeButton.action = #selector(closeTapped(_:))
    addSubview(indicator)
    addSubview(chevronButton)
    addSubview(label)
    addSubview(closeButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),

      indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      indicator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      indicator.widthAnchor.constraint(equalToConstant: 3),

      // Chevron occupies the same leading slot as the accent indicator
      // — they're mutually exclusive (one is hidden whenever the other
      // is visible) so the label position never shifts on hover.
      chevronButton.centerXAnchor.constraint(equalTo: indicator.centerXAnchor),
      chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevronButton.widthAnchor.constraint(equalToConstant: 14),
      chevronButton.heightAnchor.constraint(equalToConstant: 14),

      label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 10),
      label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 18),
      closeButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  private func configure(
    title: String, accentColor: NSColor, isCurrent: Bool, isPrivate: Bool
  ) {
    self.accentColor = accentColor
    label.stringValue = title
    label.font = isCurrent ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
    label.alphaValue = isCurrent ? 1.0 : 0.6
    indicator.color =
      isCurrent ? accentColor : accentColor.withAlphaComponent(0.6)
    indicator.isPrivate = isPrivate
    updateChevronIcon()
  }

  private func updateChevronIcon() {
    let symbol = isCollapsed ? "chevron.right" : "chevron.down"
    let description = isCollapsed ? "Expand workspace" : "Collapse workspace"
    chevronButton.image = NSImage(
      systemSymbolName: symbol, accessibilityDescription: description)
    chevronButton.contentTintColor = accentColor
    chevronButton.toolTip = description
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
    // After a fold/unfold (or any other reload that wipes and rebuilds
    // the worklane stack), AppKit doesn't synthesise a `mouseEntered`
    // for a freshly installed tracking area whose bounds already
    // contain the cursor — the row would stay un-highlighted until
    // the user moved the cursor out and back in. Probe the live
    // cursor position and resolve the hover state ourselves so the
    // affordance survives the reload. Probing the *exit* side too is
    // important here (unlike `EdgeHoverHitZoneView`, where exit
    // probes broke the timer pipeline): worklane rows have no
    // deferred timers, only direct visual flips, so syncing both
    // directions is safe.
    syncHoverWithCurrentCursor()
  }

  override func mouseEntered(with _: NSEvent) {
    setHovered(true)
  }

  override func mouseExited(with _: NSEvent) {
    setHovered(false)
  }

  private func syncHoverWithCurrentCursor() {
    guard let window else { return }
    let mouseInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    setHovered(bounds.contains(mouseInView))
  }

  private func setHovered(_ hovered: Bool) {
    guard hovered != isHovered else { return }
    isHovered = hovered
    indicator.isHidden = hovered
    chevronButton.isHidden = !hovered
    closeButton.isHidden = !hovered
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

  @objc private func chevronTapped(_: NSButton) {
    onToggleCollapse?()
  }

  @objc private func closeTapped(_: NSButton) {
    onClose?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
