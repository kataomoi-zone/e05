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
/// AppKit's disclosure triangle on the leading indent handles
/// expand / collapse.
@MainActor
final class WorklaneColumnCellView: NSTableCellView {
  static let height: CGFloat = 24
  private static let iconSize: CGFloat = 14

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")

  private weak var node: WorklaneColumnNode?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

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

    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      titleLabel.leadingAnchor.constraint(
        equalTo: iconView.trailingAnchor, constant: 6),
      titleLabel.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -6),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  func configure(
    node: WorklaneColumnNode,
    input: WorklaneSectionView.ReloadInput
  ) {
    self.node = node
    let count = node.model.panes.count
    titleLabel.stringValue = count == 1 ? "1 pane" : "\(count) panes"
  }
}
