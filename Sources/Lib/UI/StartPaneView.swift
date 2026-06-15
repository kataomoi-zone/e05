import AppKit

/// Native start page shown for a new pane in place of `about:blank`.
/// Offers quick actions to turn the pane into a terminal or finder;
/// typing a URL in the URL bar switches it to a browser. The host wires
/// the callbacks to the same content-switch path the URL bar uses, so a
/// click replaces this pane rather than spawning a stray empty one.
@MainActor
public final class StartPaneView: NSView {
  /// Called when the user picks "Terminal".
  public var onOpenTerminal: (() -> Void)?
  /// Called when the user picks "Finder".
  public var onOpenFinder: (() -> Void)?
  /// Fired when the pane body is clicked, so the host can move focus
  /// onto this pane — mirrors the other pane views' `onFocusChanged`.
  /// The quick-action buttons are subviews, so a click on them is
  /// delivered to the button and never reaches `mouseDown` below.
  public var onFocusChanged: (() -> Void)?

  public override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = AppColors.paneSurface.cgColor
    setupUI()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    layer?.backgroundColor = AppColors.paneSurface.cgColor
  }

  private func setupUI() {
    let terminalButton = Self.makeActionButton(
      title: "Terminal", symbol: "apple.terminal", action: #selector(openTerminalClicked))
    let finderButton = Self.makeActionButton(
      title: "Finder", symbol: "folder", action: #selector(openFinderClicked))
    for button in [terminalButton, finderButton] { button.target = self }

    let row = NSStackView(views: [terminalButton, finderButton])
    row.orientation = .horizontal
    row.spacing = 16
    row.translatesAutoresizingMaskIntoConstraints = false
    addSubview(row)
    NSLayoutConstraint.activate([
      row.centerXAnchor.constraint(equalTo: centerXAnchor),
      row.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @objc private func openTerminalClicked() { onOpenTerminal?() }
  @objc private func openFinderClicked() { onOpenFinder?() }

  /// A click on the empty pane body focuses the pane (the start page
  /// has no first-responder content of its own, so without this the
  /// pane is unfocusable except via its buttons or the worklane).
  public override func mouseDown(with _: NSEvent) {
    onFocusChanged?()
  }

  private static func makeActionButton(
    title: String, symbol: String, action: Selector
  ) -> NSButton {
    let button = NSButton(title: title, target: nil, action: action)
    button.bezelStyle = .regularSquare
    button.imageScaling = .scaleProportionallyDown
    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
      button.image = image
      button.imagePosition = .imageLeading
    }
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
    button.heightAnchor.constraint(equalToConstant: 56).isActive = true
    return button
  }
}
