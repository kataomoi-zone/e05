import AppKit

/// One row in the sidebar worklane section representing a single pane.
/// Indented under its owning workspace header. The currently focused
/// pane gets a 2pt border in the current workspace's accent color
/// (matching the in-content focus border) so the sidebar mirrors the
/// workspace focus state. A non-current workspace's would-be-focused
/// pane (the one a switch would land on) gets a small accent dot in
/// the leading inset — visible enough to tell the user where focus
/// will land without competing with the active workspace's full
/// border.
///
/// Clicking fires `onClick` which the sidebar routes to
/// `PaneContainerViewController.focusPane(id:)` (cross-WS safe).
/// The hover-revealed × button fires `onClose`, which routes to
/// `PaneContainerViewController.closePane(id:)`.
@MainActor
final class PaneRow: NSView {
  static let height: CGFloat = 24
  static let iconSize: CGFloat = 16

  let paneId: ULID
  var onClick: (() -> Void)?
  var onClose: (() -> Void)?
  /// Speaker glyph at the row's leading edge was tapped. Routes
  /// through the host so the click is forwarded to the pane's mute
  /// toggle no matter which workspace owns the pane.
  var onAudioToggle: (() -> Void)?

  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let focusDot = NSView()
  private static let focusDotSize: CGFloat = 6
  /// Dashed-circle ring drawn around the favicon while the pane is
  /// memory-saver-suspended. Mounted on the row's own layer (not the
  /// iconView's) so the stroke can sit *outside* the 16pt favicon
  /// slot without clipping. Toggled via `isHidden` rather than torn
  /// down so the row layout doesn't shift when the affordance
  /// appears or disappears. `nil` until the first
  /// `applySuspendedState(true)` actually needs it.
  private var suspendedRingLayer: CAShapeLayer?
  /// True while the row is showing the suspended affordance.
  /// Tracked so the layout pass can redraw the ring on frame changes
  /// without having to re-derive the state, and so
  /// `applySuspendedState` can compute alpha from a base value
  /// instead of multiplying re-entrantly.
  private var isSuspendedState: Bool = false
  /// Base (non-suspended) icon alpha picked by `configure` from the
  /// row's current / non-current state. `applySuspendedState`
  /// multiplies this by `suspendedAlpha` when the pane sleeps and
  /// restores the unscaled value when it wakes — calling
  /// `applySuspendedState(true)` twice on the same row used to dim
  /// the alpha twice before this was extracted.
  private var baseIconAlpha: CGFloat = 1.0
  private var baseLabelAlpha: CGFloat = 1.0
  private static let suspendedRingPadding: CGFloat = 2
  private static let suspendedAlpha: CGFloat = 0.5
  private static let inactiveIconAlpha: CGFloat = 0.75
  private static let inactiveLabelAlpha: CGFloat = 0.8
  private let closeButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close pane")
    b.toolTip = "Close pane"
    b.isHidden = true
    return b
  }()
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isCurrentPane = false

  /// Small clickable speaker glyph next to the favicon that surfaces
  /// the pane's current audio state and toggles mute on click. Always
  /// visible (no hover gate) when audio is active so a noisy tab is
  /// spottable without the user first pointing at the row.
  private let audioIndicator: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.isHidden = true
    // The button shouldn't capture key navigation away from the
    // worklane row — keyboard focus belongs to the row's parent
    // surface, not the trailing-edge icon.
    b.refusesFirstResponder = true
    return b
  }()
  private static let audioIndicatorSize: CGFloat = 14
  /// Title leading anchors to the audio indicator's trailing edge
  /// when audio is active and falls back to the favicon when it
  /// isn't, so the title shifts right to make room for the speaker
  /// rather than overlapping it.
  private var labelLeadingToIcon: NSLayoutConstraint?
  private var labelLeadingToAudio: NSLayoutConstraint?

  init(
    paneId: ULID, title: String, icon: NSImage?, accentColor: NSColor,
    isCurrent: Bool, isOwnWorkspaceFocus: Bool, isPrivate: Bool,
    isMuted: Bool, isPlayingAudio: Bool, hasActiveMedia: Bool,
    isSuspended: Bool
  ) {
    self.paneId = paneId
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
    configure(
      title: title, icon: icon, accentColor: accentColor,
      isCurrent: isCurrent, isOwnWorkspaceFocus: isOwnWorkspaceFocus,
      isPrivate: isPrivate)
    applyAudioState(
      isMuted: isMuted, isPlayingAudio: isPlayingAudio,
      hasActiveMedia: hasActiveMedia)
    applySuspendedState(isSuspended)
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

    focusDot.translatesAutoresizingMaskIntoConstraints = false
    focusDot.wantsLayer = true
    focusDot.isHidden = true
    addSubview(focusDot)

    closeButton.target = self
    closeButton.action = #selector(closeTapped(_:))
    addSubview(closeButton)

    audioIndicator.target = self
    audioIndicator.action = #selector(audioTapped(_:))
    addSubview(audioIndicator)

    let labelToIcon = label.leadingAnchor.constraint(
      equalTo: iconView.trailingAnchor, constant: 6)
    let labelToAudio = label.leadingAnchor.constraint(
      equalTo: audioIndicator.trailingAnchor, constant: 4)
    labelToIcon.isActive = true
    labelToAudio.isActive = false
    labelLeadingToIcon = labelToIcon
    labelLeadingToAudio = labelToAudio

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      // Dot marks "focus would land here" for non-current
      // workspaces. Centred in the leading inset (the same gutter
      // the workspace header uses for its 3pt accent indicator),
      // so the two affordances read as parts of the same focus-
      // signalling vocabulary without overlapping the icon slot.
      focusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
      focusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
      focusDot.widthAnchor.constraint(equalToConstant: Self.focusDotSize),
      focusDot.heightAnchor.constraint(equalToConstant: Self.focusDotSize),
      // Favicon / SF-symbol slot sits in the indent that used to be
      // pure whitespace, giving browser and terminal rows a visual
      // identifier without pushing text further right.
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      // Audio indicator slots between favicon and title, occupying
      // a 14pt clickable target. Hidden when audio is neither
      // playing nor muted; the title's leading dual-constraint
      // collapses the slot away so quiet rows lay out unchanged.
      audioIndicator.leadingAnchor.constraint(
        equalTo: iconView.trailingAnchor, constant: 4),
      audioIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
      audioIndicator.widthAnchor.constraint(equalToConstant: Self.audioIndicatorSize),
      audioIndicator.heightAnchor.constraint(equalToConstant: Self.audioIndicatorSize),

      label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 16),
      closeButton.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  /// Drive the leading-edge speaker glyph from the pane's audio
  /// state. Visible when audio is actually emitting, or when the
  /// pane is muted *and* a media element is still active — the
  /// second branch keeps the unmute affordance on a tab whose
  /// audible playback we just silenced. Click toggles mute through
  /// ``onAudioToggle``; the row's own click handler is bypassed
  /// because AppKit dispatches button hits to the button before
  /// falling back to the enclosing view's `mouseDown(with:)`.
  ///
  /// Internal so the worklane can re-fire it for a single row when
  /// a pane's audio state flips, without rebuilding the full list.
  func applyAudioState(isMuted: Bool, isPlayingAudio: Bool, hasActiveMedia: Bool) {
    let active = isPlayingAudio || (isMuted && hasActiveMedia)
    audioIndicator.isHidden = !active
    labelLeadingToIcon?.isActive = !active
    labelLeadingToAudio?.isActive = active
    if active {
      let symbol = isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
      let desc = isMuted ? "Unmute tab" : "Mute tab"
      let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
      audioIndicator.image = NSImage(
        systemSymbolName: symbol, accessibilityDescription: desc
      )?.withSymbolConfiguration(config)
      audioIndicator.toolTip = desc
    } else {
      audioIndicator.image = nil
      audioIndicator.toolTip = nil
    }
  }

  /// Toggle the "memory saved" affordance on the row: a dashed-circle
  /// ring around the favicon plus a reduced alpha on icon and title.
  /// Both cues are needed — the ring alone reads as decorative on
  /// rows whose icon is itself rectangular (terminal SF-symbol, site
  /// favicons without a circular crop), and alpha alone is easy to
  /// confuse with the non-current-workspace dim already applied to
  /// inactive rows. Together they read unambiguously as "this pane
  /// is asleep". Internal so the worklane can flip the state on a
  /// single row without rebuilding the list.
  ///
  /// Alpha is computed absolutely (`base * mul`) rather than by
  /// repeated multiplication so the method is idempotent and survives
  /// being called twice in a row (e.g. an init-time set followed by
  /// a redundant `updatePaneSuspendedState` from the worklane refresh
  /// path).
  func applySuspendedState(_ isSuspended: Bool) {
    isSuspendedState = isSuspended
    let mul: CGFloat = isSuspended ? Self.suspendedAlpha : 1.0
    iconView.alphaValue = baseIconAlpha * mul
    label.alphaValue = baseLabelAlpha * mul
    if isSuspended {
      installSuspendedRingIfNeeded()
      suspendedRingLayer?.isHidden = false
      updateSuspendedRingFrame()
    } else {
      suspendedRingLayer?.isHidden = true
    }
  }

  private func installSuspendedRingIfNeeded() {
    guard suspendedRingLayer == nil else { return }
    let ring = CAShapeLayer()
    ring.fillColor = nil
    ring.strokeColor = NSColor.tertiaryLabelColor.cgColor
    ring.lineWidth = 1
    ring.lineDashPattern = [3, 2]
    // Mount on the row's own layer rather than the iconView's so the
    // ring sits *outside* the favicon footprint without expanding the
    // image view's intrinsic 16pt slot — a layer added to iconView
    // would clip to its bounds and the ring would slice through.
    layer?.addSublayer(ring)
    suspendedRingLayer = ring
  }

  private func updateSuspendedRingFrame() {
    guard let ring = suspendedRingLayer, isSuspendedState else { return }
    let iconFrame = iconView.frame
    let padding = Self.suspendedRingPadding
    let ringRect = iconFrame.insetBy(dx: -padding, dy: -padding)
    let path = CGPath(ellipseIn: ringRect, transform: nil)
    // Disable implicit animation: the ring should snap to its new
    // position when the row resizes (sidebar reveal / hover-peek)
    // rather than crawl across.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.path = path
    ring.frame = bounds
    CATransaction.commit()
  }

  override func layout() {
    super.layout()
    updateSuspendedRingFrame()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    // `CAShapeLayer.strokeColor` is a CGColor snapshot, so the
    // dynamic `tertiaryLabelColor` value taken at install time stays
    // frozen across appearance changes. Re-resolve it under the new
    // appearance whenever the system flips. The app currently runs
    // dark-only so this is dormant in practice, but the cost is one
    // assignment and it removes a foot-gun for the eventual light-
    // theme work.
    guard let ring = suspendedRingLayer else { return }
    effectiveAppearance.performAsCurrentDrawingAppearance {
      ring.strokeColor = NSColor.tertiaryLabelColor.cgColor
    }
  }

  private func configure(
    title: String, icon: NSImage?, accentColor: NSColor,
    isCurrent: Bool, isOwnWorkspaceFocus: Bool, isPrivate: Bool
  ) {
    isCurrentPane = isCurrent
    label.stringValue = title
    baseIconAlpha = isCurrent ? 1.0 : Self.inactiveIconAlpha
    baseLabelAlpha = isCurrent ? 1.0 : Self.inactiveLabelAlpha
    iconView.image = icon
    // Re-apply through the suspended path so a row that boots
    // current-and-suspended (or flips current state while suspended)
    // lands on `base * suspendedAlpha`, not on the bare base.
    iconView.alphaValue = baseIconAlpha * (isSuspendedState ? Self.suspendedAlpha : 1.0)
    label.alphaValue = baseLabelAlpha * (isSuspendedState ? Self.suspendedAlpha : 1.0)
    // Private workspace rows trade the solid layer border for a
    // dotted overlay so the sidebar mirrors the in-content focus
    // indicator's visual language.
    subviews.removeAll { $0 is DottedBorderOverlay }
    if isCurrent {
      layer?.cornerRadius = 4
      if isPrivate {
        layer?.borderWidth = 0
        layer?.borderColor = nil
        let overlay = DottedBorderOverlay(frame: bounds)
        overlay.borderColor = accentColor
        overlay.borderWidth = 2
        overlay.cornerRadius = 4
        addSubview(overlay)
      } else {
        layer?.borderWidth = 2
        layer?.borderColor = accentColor.cgColor
      }
    } else {
      layer?.borderWidth = 0
      layer?.borderColor = nil
      layer?.cornerRadius = 0
    }
    if isOwnWorkspaceFocus {
      // Match the 0.6 alpha the workspace header uses on its label
      // and accent indicator when its workspace isn't the focused
      // one — the dot belongs to that same de-emphasised "preview"
      // tier and reads as too loud at full alpha.
      focusDot.layer?.backgroundColor =
        accentColor.withAlphaComponent(0.6).cgColor
      focusDot.layer?.cornerRadius = Self.focusDotSize / 2
      focusDot.isHidden = false
    } else {
      focusDot.isHidden = true
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let old = trackingArea { removeTrackingArea(old) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
    // Sync hover with the live cursor position. AppKit doesn't fire
    // `mouseEntered` for a tracking area whose bounds already
    // contain the cursor at install time, so a worklane reload (e.g.
    // a workspace fold/unfold or a focus change) would leave a row
    // un-highlighted under a stationary cursor until the user moves
    // off and back in. Probing both directions is safe here because
    // the row has no deferred timers — only direct visual flips.
    syncHoverWithCurrentCursor()
  }

  override func mouseEntered(with _: NSEvent) {
    setHovered(true)
  }

  override func mouseExited(with _: NSEvent) {
    setHovered(false)
  }

  private func syncHoverWithCurrentCursor() {
    guard let window else { return }
    let mouseInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    setHovered(bounds.contains(mouseInView))
  }

  private func setHovered(_ hovered: Bool) {
    guard hovered != isHovered else { return }
    isHovered = hovered
    closeButton.isHidden = !hovered
    applyHoverBackground()
  }

  private func applyHoverBackground() {
    // Skip the hover tint on the focused pane: it already wears a
    // 2pt accent border, and stacking a translucent fill on top of
    // that reads as a state change instead of a hover affordance.
    if isCurrentPane {
      layer?.backgroundColor = nil
      return
    }
    layer?.backgroundColor =
      isHovered ? AppColors.hoverOverlay.cgColor : nil
    layer?.cornerRadius = isHovered ? 4 : 0
  }

  override func mouseDown(with _: NSEvent) {
    onClick?()
  }

  @objc private func closeTapped(_: NSButton) {
    onClose?()
  }

  @objc private func audioTapped(_: NSButton) {
    onAudioToggle?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
