import AppKit

/// Cell view for a multi-pane column row in the worklane outline view.
/// Single-pane columns expose their pane directly as a workspace
/// child; only columns with two or more panes get this group-style
/// wrapper so the column dimension stays out of sight when it isn't
/// load-bearing.
///
/// Renders a vertical-split SF symbol + a pane count, deliberately
/// without a `Column` / `Stack` literal so the visualisation doesn't
/// commit to a terminology choice the user might want to revisit.
/// A hover-revealed × on the trailing edge closes every pane in the
/// column in one gesture, routed through `onColumnClose` so the
/// container can bulk-confirm any ghostty surfaces with running
/// processes before tearing down.
@MainActor
final class WorklaneColumnCellView: NSTableCellView {
  static let height: CGFloat = 24
  private static let iconSize: CGFloat = 14

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let closeButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "xmark",
      accessibilityDescription: "Close every pane in this column")
    b.toolTip = "Close every pane in this column"
    b.setRevealed(false)
    return b
  }()

  private var trackingArea: NSTrackingArea?
  private var isHovered = false

  private weak var node: WorklaneColumnNode?
  private var onCloseHandler: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func prepareForReuse() {
    super.prepareForReuse()
    setHovered(false)
  }

  private func setupLayout() {
    wantsLayer = true
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.imageFrameStyle = .none
    // Vertical split shape — visually echoes the column's actual
    // layout (panes stacked top-to-bottom inside a horizontal
    // workspace strip).
    iconView.image = NSImage(
      systemSymbolName: "rectangle.split.1x2",
      accessibilityDescription: "Pane stack")
    iconView.contentTintColor = .secondaryLabelColor
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.drawsBackground = false
    titleLabel.font = NSFont.systemFont(ofSize: 11)
    titleLabel.textColor = .secondaryLabelColor
    addSubview(titleLabel)

    closeButton.target = self
    closeButton.action = #selector(closeTapped(_:))
    addSubview(closeButton)

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.leadingAnchor.constraint(
        equalTo: iconView.trailingAnchor, constant: 6),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 16),
      closeButton.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  func configure(
    node: WorklaneColumnNode,
    input: WorklaneSectionView.ReloadInput
  ) {
    self.node = node
    let count = node.model.panes.count
    titleLabel.stringValue = count == 1 ? "1 pane" : "\(count) panes"
    let columnId = node.id
    onCloseHandler = {
      [onClose = input.onColumnClose] in onClose(columnId)
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
    setHovered(true)
  }

  override func mouseExited(with _: NSEvent) {
    if cursorIsStillInsideBounds() { return }
    setHovered(false)
  }

  private func setHovered(_ hovered: Bool) {
    guard hovered != isHovered else { return }
    isHovered = hovered
    closeButton.setRevealed(hovered)
    layer?.backgroundColor =
      hovered ? AppColors.hoverOverlay.cgColor : nil
    layer?.cornerRadius = hovered ? 4 : 0
  }

  @objc private func closeTapped(_: NSButton) {
    onCloseHandler?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
