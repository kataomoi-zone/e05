import AppKit

/// Workspace-header cell in the worklane outline view. Renders a 3pt
/// accent indicator (solid pill, or vertical dashed line for private
/// workspaces) plus the workspace title, with a hover-revealed × on
/// the trailing edge for close. Expand / collapse is driven by
/// AppKit's built-in disclosure triangle on the leading indent — the
/// cell itself doesn't paint a chevron.
///
/// Workspace switch is dispatched through the outline view's
/// selection model: when the user clicks the header, the row
/// becomes the table's selected row and the section view's
/// `selectionDidChange` calls `onWorkspaceClick(index:)`. Selection
/// is transient — the subsequent reload re-targets to the new
/// workspace's focused pane.
@MainActor
final class WorklaneWorkspaceCellView: NSTableCellView {
  static let height: CGFloat = 28

  private let indicator = WorkspaceAccentIndicator()
  private let label = NSTextField(labelWithString: "")
  private let closeButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "xmark", accessibilityDescription: "Close workspace")
    b.toolTip = "Close workspace"
    b.setRevealed(false)
    return b
  }()
  private let addButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "plus", accessibilityDescription: "New browser pane in this workspace")
    b.toolTip = "New browser pane in this workspace"
    b.setRevealed(false)
    return b
  }()

  private var trackingArea: NSTrackingArea?
  private var isHovered = false

  private weak var node: WorklaneWorkspaceNode?
  private var onCloseHandler: (() -> Void)?
  private var onAddHandler: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func prepareForReuse() {
    super.prepareForReuse()
    // Hover state belongs to the previous row this cell represented.
    // Reset it before reconfigure so the close × button and hover
    // background don't bleed from one workspace header to another
    // when AppKit recycles the cell.
    setHovered(false)
  }

  private func setupLayout() {
    wantsLayer = true
    indicator.translatesAutoresizingMaskIntoConstraints = false

    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.drawsBackground = false

    closeButton.target = self
    closeButton.action = #selector(closeTapped(_:))
    addButton.target = self
    addButton.action = #selector(addTapped(_:))

    addSubview(indicator)
    addSubview(label)
    addSubview(addButton)
    addSubview(closeButton)

    NSLayoutConstraint.activate([
      indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      indicator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      indicator.widthAnchor.constraint(equalToConstant: 3),

      label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 8),
      label.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      addButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
      addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 18),
      addButton.heightAnchor.constraint(equalToConstant: 18),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 18),
      closeButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  func configure(
    node: WorklaneWorkspaceNode,
    input: WorklaneSectionView.ReloadInput
  ) {
    self.node = node
    let title = "Workspace \(node.index + 1)"
    let accent = input.accentColor(node.index)
    let isCurrent = node.index == input.focusedWorkspaceIndex
    label.stringValue = title
    label.font =
      isCurrent
      ? NSFont.boldSystemFont(ofSize: 13)
      : NSFont.systemFont(ofSize: 13)
    label.alphaValue = isCurrent ? 1.0 : 0.6
    indicator.color =
      isCurrent ? accent : accent.withAlphaComponent(0.6)
    indicator.isPrivate = node.model.isPrivate

    let workspaceIndex = node.index
    let workspaceId = node.id
    onCloseHandler = {
      [onClose = input.onWorkspaceClose] in onClose(workspaceIndex)
    }
    onAddHandler = {
      [onAdd = input.onAddPaneToWorkspace] in onAdd(workspaceId)
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
    addButton.setRevealed(hovered)
    layer?.backgroundColor =
      hovered ? AppColors.hoverOverlay.cgColor : nil
    layer?.cornerRadius = hovered ? 4 : 0
  }

  @objc private func closeTapped(_: NSButton) {
    onCloseHandler?()
  }

  @objc private func addTapped(_: NSButton) {
    onAddHandler?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
