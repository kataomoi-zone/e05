import AppKit

/// One row in the sidebar worklane section representing a workspace.
/// Shows a 3pt vertical color indicator (position-based accent) + the
/// workspace name. The current workspace is rendered bold with
/// full-alpha indicator, others in 0.6 alpha for visual de-emphasis.
/// Clicking fires `onClick` which the sidebar routes to
/// `PaneContainerViewController.switchWorkspace(to:)`.
@MainActor
final class WorkspaceHeaderRow: NSView {
  static let height: CGFloat = 28

  let workspaceIndex: Int
  var onClick: (() -> Void)?

  private let indicator = NSView()
  private let label = NSTextField(labelWithString: "")

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
    addSubview(indicator)
    addSubview(label)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),

      indicator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      indicator.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      indicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
      indicator.widthAnchor.constraint(equalToConstant: 3),

      label.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 10),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
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

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
