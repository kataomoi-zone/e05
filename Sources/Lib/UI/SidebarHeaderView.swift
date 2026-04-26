import AppKit

/// Top 36pt strip inside the sidebar overlay. The left portion sits
/// under the OS traffic lights (which stay at their default position
/// thanks to `titlebarAppearsTransparent`); the trailing edge hosts the
/// pin toggle button. Click invokes `onTogglePin`, which the view
/// controller routes into the `SidebarState` machine.
@MainActor
final class SidebarHeaderView: NSView {
  static let height: CGFloat = 36

  /// Leading inset that clears the OS traffic lights. Measured on
  /// macOS 26 (Tahoe) where the standard close/min/zoom cluster
  /// occupies ~70pt; 78pt gives an 8pt gap to the app title that
  /// follows. Values may drift on later OS versions; if the title
  /// starts overlapping the buttons, switch to a runtime read of
  /// `window.standardWindowButton(.closeButton)?.superview?.frame.maxX`
  /// instead of this constant.
  private static let trafficLightInset: CGFloat = 78

  let pinButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    return b
  }()

  // TODO: read the version segment from `CFBundleShortVersionString`
  // once a release pipeline exists; the literal serves until then.
  private let titleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "E05 alpha")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.drawsBackground = false
    return label
  }()

  /// Invoked when the user clicks the pin toggle. The view controller
  /// owns the state machine — this view only reports intent.
  var onTogglePin: (() -> Void)?

  /// Drives the pin icon glyph and accessibility text. When `true`,
  /// the filled pin emphasises the "currently pinned" state; when
  /// `false`, the outline pin signals the action the click will take
  /// (pin the sidebar).
  var isPinned: Bool = false {
    didSet { updatePinAppearance() }
  }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupLayout()
    updatePinAppearance()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    pinButton.target = self
    pinButton.action = #selector(pinTapped(_:))
    addSubview(pinButton)
    addSubview(titleLabel)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      pinButton.widthAnchor.constraint(equalToConstant: 22),
      pinButton.heightAnchor.constraint(equalToConstant: 22),
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trafficLightInset),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  private func updatePinAppearance() {
    let symbol = isPinned ? "pin.fill" : "pin"
    let description = isPinned ? "Unpin sidebar" : "Pin sidebar"
    pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    pinButton.toolTip = description
  }

  @objc private func pinTapped(_: NSButton) {
    onTogglePin?()
  }
}
