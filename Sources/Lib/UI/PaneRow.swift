import AppKit

/// One row in the sidebar worklane section representing a single pane.
/// Indented under its owning workspace header. The currently focused
/// pane gets a 2pt border in the current workspace's accent color
/// (matching the in-content focus border) so the sidebar mirrors the
/// workspace focus state. Clicking fires `onClick` which the sidebar
/// routes to `PaneContainerViewController.focusPane(id:)` (cross-WS
/// safe via the stage 0-A API).
@MainActor
final class PaneRow: NSView {
  static let height: CGFloat = 24
  static let iconSize: CGFloat = 16

  let paneId: ULID
  var onClick: (() -> Void)?

  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")

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
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  private func configure(title: String, icon: NSImage?, accentColor: NSColor, isCurrent: Bool) {
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

  override func mouseDown(with event: NSEvent) {
    onClick?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
