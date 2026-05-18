import AppKit

/// Stand-in shown by ``BrowserPaneView`` while its `WKWebView` is
/// detached by `suspend()`. Renders the captured title and URL plus
/// a "suspended" affordance so the user knows the pane is alive
/// but unloaded; clicking anywhere on the placeholder fires
/// ``onClick`` so the host can route the click through the normal
/// focus handler and trigger a `restore()`.
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
  private let suspendedLabel = NSTextField(labelWithString: "Suspended · Focus to load")

  /// Fired by a click anywhere on the placeholder's bounds. The host
  /// wires this to its focus handler so the pane lands in the normal
  /// focus path that already calls `restoreIfSuspended()`.
  var onClick: (() -> Void)?

  /// `BrowserPaneView.firstResponderTarget` hands this view back as
  /// the first-responder destination while the pane is suspended,
  /// so the placeholder needs to accept the role for the responder
  /// chain to stay coherent (otherwise `makeFirstResponder` lands
  /// on the host window and the focused pane has no live responder
  /// route for keystrokes).
  override var acceptsFirstResponder: Bool { true }

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
    onClick?()
  }
}
