import AppKit

/// Thin loading bar pinned above a pane. Without a `progress`, a
/// short comet slides back and forth across the bar while a
/// navigation is in flight — `WKWebView.estimatedProgress` typically
/// reports only a 0 → 1 transition for most pages, so a determinate
/// fill sat at 0% for the entire load before snapping to 100%. The
/// shuttle keeps continuous motion the user can read as "still
/// loading" without trusting an unreliable percentage. A terminal
/// pane's program can report a real one, which fills the bar instead.
///
/// Click-through (`hitTest` returns nil) so the bar never blocks
/// page interaction.
@MainActor
public final class LoadingProgressBarView: NSView {
  /// How long a load has to run before the bar fades in. Fast loads
  /// finish before this fires and the bar never appears — only
  /// show when the user would notice the wait.
  public static let revealDelay: TimeInterval = 0.5
  public static let height: CGFloat = 2.5
  private static let revealDuration: TimeInterval = 0.18
  private static let dismissDuration: TimeInterval = 0.28
  /// Fraction of the bar's width filled by the moving comet.
  private static let cometFraction: CGFloat = 0.35
  /// One full left → right → left cycle.
  private static let shuttleDuration: CFTimeInterval = 1.2
  private static let fillDuration: TimeInterval = 0.2

  /// Faint accent baseline drawn under the comet so the bar reads
  /// as a continuous strip even at the instant the comet sits at
  /// either edge.
  private static let baselineAlpha: CGFloat = 0.22

  /// The moving comet. Frame width is recomputed in `layout()`
  /// from the parent's current width.
  private let comet: NSView = {
    let v = NSView()
    v.wantsLayer = true
    return v
  }()

  /// Filled from the leading edge to `progress`, in place of the comet.
  private let fill: NSView = {
    let v = NSView()
    v.wantsLayer = true
    v.isHidden = true
    return v
  }()

  /// True while revealed. Tracked separately from `alphaValue` so a
  /// `layout()` resize while revealed restarts the shuttle with
  /// current bounds-derived endpoints.
  private var isRevealed = false

  /// How far along the work is, from 0 to 1. `nil` shuttles the comet
  /// for work that reports no measure.
  public var progress: Double? {
    didSet {
      guard progress != oldValue else { return }
      comet.isHidden = progress != nil
      fill.isHidden = progress == nil
      // A hidden bar snaps, so it never reappears sliding from the
      // last run's value.
      layoutFill(animated: isRevealed && oldValue != nil)
      if progress != nil {
        stopShuttle()
      } else if isRevealed {
        installShuttleAnimation()
      }
    }
  }

  /// Bar tint. Driven by the host workspace's accent so the bar
  /// matches the focus border and worklane spinner; falls back to
  /// the system accent for callers that don't supply one.
  public var accent: NSColor = .controlAccentColor {
    didSet { applyAccent() }
  }

  /// Overrides `accent` when the work's state is the news, such as a
  /// failure. The host keeps `accent` in step with the workspace, so
  /// this stays separate.
  public var tint: NSColor? {
    didSet { applyAccent() }
  }

  /// Last bar width an animation was installed for. The shuttle's
  /// translation endpoints depend on the bar width, so `layout()`
  /// only re-installs the animation when the width actually changed —
  /// re-installing on every layout pass snapped the comet back to
  /// the leading edge whenever AppKit ran an incidental layout
  /// (resize handle drag, equal-height adjust).
  private var lastShuttleWidth: CGFloat = 0

  public override init(frame: NSRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setup() {
    wantsLayer = true
    addSubview(comet)
    addSubview(fill)
    alphaValue = 0
    applyAccent()
  }

  /// Click-through: the bar is decorative chrome.
  public override func hitTest(_: NSPoint) -> NSView? { nil }

  public override func layout() {
    super.layout()
    let cometWidth = bounds.width * Self.cometFraction
    comet.frame = NSRect(x: 0, y: 0, width: cometWidth, height: bounds.height)
    layoutFill(animated: false)
    if isRevealed, progress == nil, bounds.width != lastShuttleWidth {
      installShuttleAnimation()
    }
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    // `controlAccentColor` (and any catalog colour passed via
    // `accent`) is dynamic; the layer caches its cgColor at the
    // appearance active when last assigned, so the appearance flip
    // needs an explicit re-resolve under the new effective
    // appearance.
    applyAccent()
  }

  private func applyAccent() {
    let color = tint ?? accent
    layer?.backgroundColor =
      color.withAlphaComponent(Self.baselineAlpha).cgColor(under: effectiveAppearance)
    comet.layer?.backgroundColor = color.cgColor(under: effectiveAppearance)
    fill.layer?.backgroundColor = color.cgColor(under: effectiveAppearance)
  }

  /// Size the fill to `progress`. A resize snaps; a new value slides,
  /// so a program reporting in coarse steps still reads as motion.
  private func layoutFill(animated: Bool) {
    let frame = NSRect(
      x: 0, y: 0, width: bounds.width * (progress ?? 0), height: bounds.height)
    guard animated else {
      fill.frame = frame
      return
    }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fillDuration
      fill.animator().frame = frame
    }
  }

  /// Fade in and start the shuttling comet, or show the fill when there
  /// is a `progress`. Re-installs the shuttle animation with current
  /// bounds when called while already revealed, so callers can resync
  /// after a bounds change without re-triggering the fade.
  public func reveal() {
    isRevealed = true
    if progress == nil { installShuttleAnimation() }
    guard alphaValue < 1 else { return }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.revealDuration
      animator().alphaValue = 1
    }
  }

  /// Fade out and stop the shuttle.
  public func dismiss() {
    guard isRevealed || alphaValue > 0 else { return }
    isRevealed = false
    stopShuttle()
    guard alphaValue > 0 else { return }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.dismissDuration
      animator().alphaValue = 0
    }
  }

  /// Stop the shuttle and clear the layer's translation so the next
  /// one starts the comet from the leading edge.
  private func stopShuttle() {
    lastShuttleWidth = 0
    comet.layer?.removeAnimation(forKey: "shuttle")
    // Remove the residual translation transform left over from the
    // animation's last frame so the next reveal isn't anchored at
    // the right edge until the animation re-installs.
    comet.layer?.transform = CATransform3DIdentity
  }

  private func installShuttleAnimation() {
    guard let cometLayer = comet.layer else { return }
    let travel = bounds.width - comet.frame.width
    guard travel > 0 else { return }
    cometLayer.removeAnimation(forKey: "shuttle")
    let anim = CABasicAnimation(keyPath: "transform.translation.x")
    anim.fromValue = 0
    anim.toValue = travel
    anim.duration = Self.shuttleDuration
    anim.autoreverses = true
    anim.repeatCount = .infinity
    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    // Without this the animation snaps off when the view briefly
    // leaves the visible tree (workspace slide, pane reorder); the
    // shuttle would visibly freeze partway through.
    anim.isRemovedOnCompletion = false
    cometLayer.add(anim, forKey: "shuttle")
    lastShuttleWidth = bounds.width
  }
}
