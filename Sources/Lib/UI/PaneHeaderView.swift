import AppKit

/// Overlay view showing the pane's terminal title.
@MainActor
public final class PaneHeaderView: NSView {
  private static let fadeInDuration: TimeInterval = 0.15
  private static let fadeOutDuration: TimeInterval = 0.3
  private static let autoHideDelay: TimeInterval = 2.0

  private let titleLabel: NSTextField = {
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .labelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 1
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  private var autoHideTimer: Timer?

  public override init(frame: NSRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AppColors.paneHeaderSurface.cgColor
    }
  }

  private func setup() {
    wantsLayer = true
    layer?.backgroundColor = AppColors.paneHeaderSurface.cgColor
    layer?.cornerRadius = 4
    alphaValue = 0  // start hidden

    addSubview(titleLabel)
    NSLayoutConstraint.activate([
      titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  // MARK: - Public API

  /// Show the header with the given title. Fades in, then auto-hides after delay.
  public func show(title: String, autoHide: Bool) {
    titleLabel.stringValue = title
    autoHideTimer?.invalidate()
    autoHideTimer = nil

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeInDuration
      self.animator().alphaValue = 1
    }

    if autoHide {
      autoHideTimer = Timer.scheduledTimer(
        withTimeInterval: Self.autoHideDelay, repeats: false
      ) { [weak self] _ in
        DispatchQueue.main.async {
          self?.hide()
        }
      }
    }
  }

  /// Fade out the header.
  public func hide() {
    autoHideTimer?.invalidate()
    autoHideTimer = nil

    NSAnimationContext.runAnimationGroup { context in
      context.duration = Self.fadeOutDuration
      self.animator().alphaValue = 0
    }
  }

  /// Immediately hide without animation.
  public func hideImmediately() {
    autoHideTimer?.invalidate()
    autoHideTimer = nil
    alphaValue = 0
  }

  public var currentTitle: String {
    titleLabel.stringValue
  }
}
