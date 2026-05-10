import AppKit

/// Stack of transient action-feedback pills along the bottom edge of the
/// container. Each pill is tinted with the current workspace's accent color
/// and self-dismisses after a short delay.
///
/// Pass-through hit-testing — the overlay must not absorb clicks meant for
/// the panes underneath. Individual pills can be tapped for early dismissal.
@MainActor
public final class ToastOverlayView: NSView {
  /// Set by `ToastCenter.attach`. Pills route their click-dismiss
  /// through here so the matching autodismiss timer gets invalidated
  /// — bypassing the center would leak the pill for the rest of the
  /// duration even though it's gone from the screen.
  weak var center: ToastCenter?

  private let stack: NSStackView = {
    let s = NSStackView()
    s.orientation = .vertical
    s.alignment = .centerX
    s.distribution = .equalSpacing
    s.spacing = 6
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
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
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  /// Pass through anywhere outside an actual pill so the overlay never
  /// blocks the underlying pane from receiving clicks. The pill itself
  /// owns the click target — toast pills don't nest interactive
  /// children, so returning the pill directly is sufficient.
  public override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    let stackPoint = stack.convert(local, from: self)
    for pill in stack.arrangedSubviews {
      if pill.frame.contains(stackPoint) {
        return pill
      }
    }
    return nil
  }

  func push(_ pill: ToastPillView) {
    // Capture each existing pill's pre-insert frame so we can run a
    // "from-old-to-new" transform tween once the stack reflows them.
    // Skip pills already mid-dismiss — animateOut owns their layer
    // transform and an additive shift would fight that animation.
    let existing = stack.arrangedSubviews.compactMap { $0 as? ToastPillView }
    let oldFrames: [(ToastPillView, NSRect)] = existing.compactMap {
      $0.isDismissing ? nil : ($0, $0.frame)
    }

    stack.addArrangedSubview(pill)
    // Resolve every arranged subview's new frame synchronously so we
    // can compute the per-pill delta and so the new pill's transform
    // tween is the only motion the user sees on it. Without forcing
    // layout here the pill's bounds are still (0,0,0,0) when
    // `animateIn` runs and the snap-to-resting frame change reads as
    // the pill "dropping" from the top.
    superview?.layoutSubtreeIfNeeded()

    // Tween each existing pill from its old position to its new one.
    // Running this as a CABasicAnimation on the layer's transform
    // matches the new pill's own slide-up animation curve and dodges
    // the implicit-animation gotchas that come with `animator()` on
    // arranged subviews managed by NSStackView.
    for (existingPill, oldFrame) in oldFrames {
      let dy = oldFrame.origin.y - existingPill.frame.origin.y
      guard dy != 0 else { continue }
      existingPill.animateShift(byDeltaY: dy)
    }

    pill.animateIn()
  }

  func remove(_ pill: ToastPillView) {
    pill.animateOut { [weak self, weak pill] in
      guard let self, let pill else { return }
      self.stack.removeArrangedSubview(pill)
      pill.removeFromSuperview()
    }
  }

  /// Tear a pill out of the stack with no animation. Used by
  /// `ToastCenter` when a fresh post would push the visible count
  /// past `maxStack` — fading out the bumped pill while the stack
  /// reflowed it upward produced a brief "flash near the top edge"
  /// as the residual fade caught up with the post-reflow position.
  /// Removing it synchronously and forcing layout means the next
  /// `push` sees a stack that has already collapsed, so the new
  /// pill's slide-up tween is the only motion the user sees.
  func discard(_ pill: ToastPillView) {
    stack.removeArrangedSubview(pill)
    pill.removeFromSuperview()
    superview?.layoutSubtreeIfNeeded()
  }
}

/// One pill in the toast stack. Solid accent fill (~85% alpha) with a
/// faint glow that lifts it above busy pane content. Tap to dismiss early.
@MainActor
public final class ToastPillView: NSView {
  private static let fadeInDuration: TimeInterval = 0.32
  private static let fadeOutDuration: TimeInterval = 0.28
  private static let slideOffset: CGFloat = 18

  private let label: NSTextField
  private weak var owner: ToastOverlayView?

  /// Set once `animateOut` starts so `ToastOverlayView.push` can skip
  /// us when computing per-pill shift tweens — fighting the dismiss
  /// transform with an additive shift produces a visible jitter.
  fileprivate var isDismissing = false

  init(message: String, accent: NSColor, owner: ToastOverlayView) {
    self.owner = owner
    let l = NSTextField(labelWithString: message)
    l.font = .systemFont(ofSize: 12, weight: .medium)
    l.textColor = NSColor(white: 1.0, alpha: 0.95)
    l.lineBreakMode = .byTruncatingTail
    l.maximumNumberOfLines = 1
    l.translatesAutoresizingMaskIntoConstraints = false
    self.label = l
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = false
    layer?.backgroundColor = accent.withAlphaComponent(0.92).cgColor
    layer?.borderWidth = 0.5
    layer?.borderColor = AppColors.toastBorder.cgColor
    // Faint glow so the pill stays visible even over high-contrast
    // pane content like dark code editors with bright syntax tokens.
    layer?.shadowColor = accent.cgColor
    layer?.shadowOpacity = 0.55
    layer?.shadowRadius = 8
    layer?.shadowOffset = .zero
    addSubview(l)
    NSLayoutConstraint.activate([
      l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      l.topAnchor.constraint(equalTo: topAnchor, constant: 7),
      l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
    ])
    alphaValue = 0
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  public override func mouseDown(with _: NSEvent) {
    // Prefer the center so the autodismiss timer also goes; fall
    // back to direct overlay removal if the overlay hasn't been
    // attached to a center (test harness path).
    if let center = owner?.center {
      center.dismiss(self)
    } else {
      owner?.remove(self)
    }
  }

  public override func resetCursorRects() {
    discardCursorRects()
    addCursorRect(bounds, cursor: .pointingHand)
  }

  func animateIn() {
    // Slide-up + fade-in on the layer's translation to avoid stacking
    // multiple AppKit constraint passes per toast. Layer animations need
    // an explicit CABasicAnimation pair so the duration / timing curve
    // override the implicit 0.25s linear default — without this the pill
    // still hops up but does it on the implicit timeline.
    // AppKit views aren't flipped by default, so layer y increases
    // upward — to slide *up* into place, the pre-animation transform
    // must offset toward negative y (below the resting position).
    let offset = Self.slideOffset
    let from = CATransform3DMakeTranslation(0, -offset, 0)
    layer?.transform = from
    let anim = CABasicAnimation(keyPath: "transform")
    anim.fromValue = NSValue(caTransform3D: from)
    anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    anim.duration = Self.fadeInDuration
    anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    layer?.add(anim, forKey: "slide")
    layer?.transform = CATransform3DIdentity
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fadeInDuration
      ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
      self.animator().alphaValue = 1
    }
  }

  func animateOut(_ completion: @escaping @MainActor () -> Void) {
    isDismissing = true
    NSAnimationContext.runAnimationGroup(
      { ctx in
        ctx.duration = Self.fadeOutDuration
        self.animator().alphaValue = 0
      },
      completionHandler: {
        MainActor.assumeIsolated { completion() }
      }
    )
  }

  /// Tween the pill from a temporarily-shifted position back to its
  /// resting frame. Called by `ToastOverlayView.push` for each
  /// existing pill after a stack reflow — `dy` is the delta from
  /// the new origin back to the old (positive = pill needs to start
  /// below its new resting position, negative = above) so the
  /// existing pill visually slides into the new layout instead of
  /// snapping. Matches the new pill's slide-up curve.
  fileprivate func animateShift(byDeltaY dy: CGFloat) {
    let from = CATransform3DMakeTranslation(0, dy, 0)
    layer?.transform = from
    let anim = CABasicAnimation(keyPath: "transform")
    anim.fromValue = NSValue(caTransform3D: from)
    anim.toValue = NSValue(caTransform3D: CATransform3DIdentity)
    anim.duration = Self.fadeInDuration
    anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    layer?.add(anim, forKey: "shift")
    layer?.transform = CATransform3DIdentity
  }
}
