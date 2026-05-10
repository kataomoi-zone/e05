import AppKit

/// Status-bar-style overlay that previews the URL under the cursor
/// while hovering a link inside a browser pane. Mirrors the fade-in
/// / fade-out affordance of `PaneHeaderView` but lives at the bottom-
/// leading corner so it doesn't collide with the page title overlay.
///
/// Mouse events pass through (`hitTest` returns nil) so the preview
/// never blocks the underlying page from receiving clicks.
@MainActor
public final class HoverLinkOverlayView: NSView {
  private static let fadeInDuration: TimeInterval = 0.08
  private static let fadeOutDuration: TimeInterval = 0.15

  private let urlLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 11, weight: .regular)
    label.textColor = NSColor(white: 1.0, alpha: 0.92)
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  public override init(frame: NSRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  private func setup() {
    wantsLayer = true
    layer?.backgroundColor = AppColors.hoverLinkSurface.cgColor
    layer?.cornerRadius = 4
    // Clip to the rounded rect so any future subview (icon, badge)
    // added inside the overlay honours the corner radius instead of
    // spilling out of the background.
    layer?.masksToBounds = true
    alphaValue = 0

    addSubview(urlLabel)
    NSLayoutConstraint.activate([
      urlLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      urlLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      urlLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
      urlLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
    ])
  }

  /// Pass-through: the overlay floats above the page content and must
  /// never intercept mouse events meant for links or scrolling.
  public override func hitTest(_: NSPoint) -> NSView? { nil }

  public var currentURL: String { urlLabel.stringValue }

  public func show(url: String) {
    // Avoid re-running the fade-in every time the side flips: the
    // overlay position swap goes through `applyHoverLinkSide` on the
    // Swift side but the JS still re-posts the same URL, so without
    // this guard each flip would queue another `alphaValue = 1`
    // transaction on top of an already-opaque overlay.
    if urlLabel.stringValue != url {
      urlLabel.stringValue = url
    }
    guard alphaValue < 1 else { return }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fadeInDuration
      self.animator().alphaValue = 1
    }
  }

  public func hide() {
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fadeOutDuration
      self.animator().alphaValue = 0
    }
  }
}
