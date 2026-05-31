import AppKit

/// Stand-in shown by ``BrowserPaneView`` while its `WKWebView` is
/// detached by `suspend()`. Renders the captured title and URL plus
/// a "Suspended" badge and an explicit Reload button.
///
/// Clicking the body of the placeholder fires ``onClick`` — wired by
/// the host to its focus handler so the pane can take focus without
/// waking up. Clicking the Reload button fires ``onReload``, the
/// only path that drops the suspended state on user demand (mirrors
/// the URL bar reload button, the Reload shortcut, and the palette
/// `Reload` action).
///
/// Intentionally lightweight: no favicon, no progress affordance, no
/// thumbnail. Richer presentation (favicon, dimmed thumbnail) can
/// land without changing this contract.
@MainActor
final class BrowserPanePlaceholderView: NSView {
  private let iconView: NSImageView = {
    let v = NSImageView()
    let config = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
    v.image = NSImage(
      systemSymbolName: "face.dashed", accessibilityDescription: "Suspended"
    )?.withSymbolConfiguration(config)
    v.contentTintColor = .tertiaryLabelColor
    return v
  }()
  private let titleLabel = NSTextField(labelWithString: "")
  private let urlLabel = NSTextField(labelWithString: "")
  private let suspendedLabel = NSTextField(labelWithString: "Suspended")
  private let reloadButton: NSButton = {
    let btn = NSButton(title: "Reload", target: nil, action: nil)
    let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    if let image = NSImage(
      systemSymbolName: "arrow.clockwise",
      accessibilityDescription: "Reload"
    )?.withSymbolConfiguration(config) {
      btn.image = image
      btn.imagePosition = .imageLeading
    }
    btn.bezelStyle = .rounded
    btn.translatesAutoresizingMaskIntoConstraints = false
    return btn
  }()

  /// Fired by a click on the placeholder body (not the Reload
  /// button). The host wires this to its focus handler — focus
  /// alone never wakes the pane, so the click only moves the focus
  /// border to this placeholder's hosting column.
  var onClick: (() -> Void)?

  /// Fired by the Reload button. The host calls `BrowserPaneView
  /// .restore()` from here, the same path the URL bar reload
  /// button and the global Reload action use for a suspended pane.
  var onReload: (() -> Void)?

  /// `BrowserPaneView.firstResponderTarget` hands this view back as
  /// the first-responder destination while the pane is suspended,
  /// so the placeholder needs to accept the role for the responder
  /// chain to stay coherent (otherwise `makeFirstResponder` lands
  /// on the host window and the focused pane has no live responder
  /// route for keystrokes).
  override var acceptsFirstResponder: Bool { true }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AppColors.paneSurface.cgColor
    }
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = AppColors.paneSurface.cgColor

    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
    titleLabel.textColor = .secondaryLabelColor
    titleLabel.lineBreakMode = .byTruncatingMiddle
    titleLabel.alignment = .center
    titleLabel.maximumNumberOfLines = 1
    addSubview(titleLabel)

    urlLabel.translatesAutoresizingMaskIntoConstraints = false
    urlLabel.font = .systemFont(ofSize: 11)
    urlLabel.textColor = .tertiaryLabelColor
    urlLabel.lineBreakMode = .byTruncatingMiddle
    urlLabel.alignment = .center
    urlLabel.maximumNumberOfLines = 1
    addSubview(urlLabel)

    suspendedLabel.translatesAutoresizingMaskIntoConstraints = false
    suspendedLabel.font = .systemFont(ofSize: 11, weight: .medium)
    suspendedLabel.textColor = .tertiaryLabelColor
    suspendedLabel.alignment = .center
    addSubview(suspendedLabel)

    reloadButton.target = self
    reloadButton.action = #selector(reloadAction)
    addSubview(reloadButton)

    NSLayoutConstraint.activate([
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.bottomAnchor.constraint(equalTo: titleLabel.topAnchor, constant: -12),
      iconView.widthAnchor.constraint(equalToConstant: 44),
      iconView.heightAnchor.constraint(equalToConstant: 44),

      titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

      urlLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
      urlLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
      urlLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),

      suspendedLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      suspendedLabel.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 12),

      reloadButton.centerXAnchor.constraint(equalTo: centerXAnchor),
      reloadButton.topAnchor.constraint(equalTo: suspendedLabel.bottomAnchor, constant: 12),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func configure(title: String?, url: URL) {
    let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let t = trimmedTitle, !t.isEmpty {
      titleLabel.stringValue = t
    } else {
      titleLabel.stringValue = url.host(percentEncoded: false) ?? url.absoluteString
    }
    urlLabel.stringValue = url.absoluteString
  }

  override func mouseDown(with event: NSEvent) {
    // The Reload button consumes its own clicks (standard `NSButton`
    // hit testing), so reaching this point means the user clicked
    // the body — that's focus-only.
    onClick?()
  }

  @objc private func reloadAction() {
    onReload?()
  }
}
