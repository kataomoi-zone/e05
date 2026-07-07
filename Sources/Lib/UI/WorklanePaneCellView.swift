import AppKit

/// Child row in the worklane outline view. Renders a favicon (or
/// terminal SF symbol) followed by the pane title, with three layered
/// affordances: a small "focus would land here" dot in the leading
/// inset for the would-be focused pane of a non-current workspace, a
/// dashed circle around the favicon while the pane is suspended, and
/// a hover-revealed × on the trailing edge for close.
/// An audio speaker glyph slips between favicon and title whenever
/// the pane is emitting or muting active audio.
///
/// Focused-pane indication is delegated to the outline view's
/// source-list selection highlight — the cell doesn't paint a border.
@MainActor
final class WorklanePaneCellView: NSTableCellView {
  static let height: CGFloat = 24
  static let iconSize: CGFloat = 16

  private let iconView = NSImageView()
  private let titleLabel = NSTextField(labelWithString: "")
  private let focusDot = NSView()
  private static let focusDotSize: CGFloat = 6
  private static let inactiveIconAlpha: CGFloat = 0.75
  private static let inactiveLabelAlpha: CGFloat = 0.8
  private static let suspendedAlpha: CGFloat = 0.5
  private static let suspendedRingPadding: CGFloat = 2

  /// Mounted on the cell's own layer (not the iconView's) so the
  /// stroke sits *outside* the 16pt favicon footprint without
  /// clipping. Toggled via `isHidden` rather than torn down so
  /// `isSuspended` flicks don't reshape the cell.
  private var suspendedRingLayer: CAShapeLayer?
  private var isSuspendedState = false
  private var baseIconAlpha: CGFloat = 1.0
  private var baseLabelAlpha: CGFloat = 1.0

  /// Fixed-size NSView that hosts the two CAShapeLayers comprising
  /// the spinner — a faint halo + a bright rotating arc. The host
  /// view is constrained to ``loadingHostSize`` square and centred on
  /// the favicon, so the layer geometry stays independent of
  /// `iconView.frame` (which is `.zero` for cells vended before their
  /// first layout pass — the "new pane just opened and is loading
  /// its first URL" path that previously rendered an eccentric ellipse).
  /// Toggled via `isHidden` to keep cell reuse cheap.
  private let loadingHostView: NSView = {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.wantsLayer = true
    v.isHidden = true
    return v
  }()
  private var loadingHaloLayer: CAShapeLayer?
  private var loadingArcLayer: CAShapeLayer?
  private var isLoadingState = false
  private static let loadingHostSize: CGFloat = 20
  private static let loadingRingLineWidth: CGFloat = 1.5
  private static let loadingHaloAlpha: CGFloat = 0.22
  /// Fraction of the circumference covered by the rotating arc.
  /// A quarter circle reads as "spinning" without the heavier
  /// silhouette a wider arc produces at the 16pt favicon size.
  private static let loadingArcStrokeEnd: CGFloat = 0.25
  private static let loadingRingRotationDuration: CFTimeInterval = 0.9

  private let pinIndicator: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Unpin column")
    b.contentTintColor = .secondaryLabelColor
    b.toolTip = "Unpin column"
    b.isHidden = true
    b.refusesFirstResponder = true
    return b
  }()
  private let foldIndicator: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "arrow.down.right.and.arrow.up.left",
      accessibilityDescription: "Unfold column")
    b.contentTintColor = .secondaryLabelColor
    b.toolTip = "Unfold column"
    b.isHidden = true
    b.refusesFirstResponder = true
    return b
  }()
  private let statusIndicatorStack: NSStackView = {
    let s = NSStackView()
    s.orientation = .horizontal
    s.spacing = 3
    s.translatesAutoresizingMaskIntoConstraints = false
    return s
  }()

  private let closeButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "xmark", accessibilityDescription: "Close pane")
    b.toolTip = "Close pane"
    b.setRevealed(false)
    return b
  }()

  /// Click target that toggles mute. Always visible when audio is
  /// active (no hover gate) so a noisy tab is spottable without first
  /// pointing at the row.
  private let audioIndicator: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.isHidden = true
    b.refusesFirstResponder = true
    return b
  }()
  private static let audioIndicatorSize: CGFloat = 14
  private var labelLeadingToIcon: NSLayoutConstraint?
  private var labelLeadingToAudio: NSLayoutConstraint?

  private var trackingArea: NSTrackingArea?
  private var isHovered = false

  private weak var node: WorklanePaneNode?
  private var onCloseHandler: (() -> Void)?
  private var onAudioToggleHandler: (() -> Void)?
  private var onPinToggleHandler: (() -> Void)?
  private var onFoldToggleHandler: (() -> Void)?

  init(identifier: NSUserInterfaceItemIdentifier) {
    super.init(frame: .zero)
    self.identifier = identifier
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func prepareForReuse() {
    super.prepareForReuse()
    // Hover state and the suspended ring carry over from the previous
    // row this cell represented. Wipe them before reconfigure so
    // close × visibility, focus dot, and the dashed favicon ring
    // don't bleed across recycled cells.
    setHovered(false)
    suspendedRingLayer?.isHidden = true
    isSuspendedState = false
    loadingHostView.isHidden = true
    loadingArcLayer?.removeAllAnimations()
    isLoadingState = false
    focusDot.isHidden = true
    pinIndicator.isHidden = true
    foldIndicator.isHidden = true
    onPinToggleHandler = nil
    onFoldToggleHandler = nil
  }

  private func setupLayout() {
    wantsLayer = true
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.imageFrameStyle = .none
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.drawsBackground = false
    titleLabel.font = NSFont.systemFont(ofSize: 12)
    addSubview(titleLabel)

    focusDot.translatesAutoresizingMaskIntoConstraints = false
    focusDot.wantsLayer = true
    focusDot.isHidden = true
    addSubview(focusDot)

    closeButton.target = self
    closeButton.action = #selector(closeTapped(_:))
    addSubview(closeButton)

    pinIndicator.target = self
    pinIndicator.action = #selector(pinTapped(_:))
    statusIndicatorStack.addArrangedSubview(pinIndicator)
    pinIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
    pinIndicator.heightAnchor.constraint(equalToConstant: 12).isActive = true

    foldIndicator.target = self
    foldIndicator.action = #selector(foldTapped(_:))
    statusIndicatorStack.addArrangedSubview(foldIndicator)
    foldIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
    foldIndicator.heightAnchor.constraint(equalToConstant: 12).isActive = true

    addSubview(statusIndicatorStack)

    audioIndicator.target = self
    audioIndicator.action = #selector(audioTapped(_:))
    addSubview(audioIndicator)

    addSubview(loadingHostView)
    installLoadingLayers()

    let labelToIcon = titleLabel.leadingAnchor.constraint(
      equalTo: iconView.trailingAnchor, constant: 6)
    let labelToAudio = titleLabel.leadingAnchor.constraint(
      equalTo: audioIndicator.trailingAnchor, constant: 4)
    labelToIcon.isActive = true
    labelToAudio.isActive = false
    labelLeadingToIcon = labelToIcon
    labelLeadingToAudio = labelToAudio

    NSLayoutConstraint.activate([
      focusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
      focusDot.centerYAnchor.constraint(equalTo: centerYAnchor),
      focusDot.widthAnchor.constraint(equalToConstant: Self.focusDotSize),
      focusDot.heightAnchor.constraint(equalToConstant: Self.focusDotSize),

      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),

      loadingHostView.centerXAnchor.constraint(equalTo: iconView.centerXAnchor),
      loadingHostView.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
      loadingHostView.widthAnchor.constraint(equalToConstant: Self.loadingHostSize),
      loadingHostView.heightAnchor.constraint(equalToConstant: Self.loadingHostSize),

      audioIndicator.leadingAnchor.constraint(
        equalTo: iconView.trailingAnchor, constant: 4),
      audioIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
      audioIndicator.widthAnchor.constraint(equalToConstant: Self.audioIndicatorSize),
      audioIndicator.heightAnchor.constraint(equalToConstant: Self.audioIndicatorSize),

      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: statusIndicatorStack.leadingAnchor, constant: -4),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      statusIndicatorStack.trailingAnchor.constraint(
        equalTo: closeButton.leadingAnchor, constant: -4),
      statusIndicatorStack.centerYAnchor.constraint(equalTo: centerYAnchor),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 16),
      closeButton.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  func configure(
    node: WorklanePaneNode,
    input: WorklaneSectionView.ReloadInput,
    focusedPaneId: ULID?
  ) {
    self.node = node
    let pane = node.model
    let ws = node.workspaceNode
    let accent = ws.map { input.accentColor($0.index) } ?? .labelColor
    let isCurrent = pane.id == focusedPaneId
    let ownFocusPaneId = ws.flatMap { wsNode in
      wsNode.model.columns[safe: wsNode.model.focusedColumnIndex]?
        .focusedPane?.id
    }
    // Show the dot for every workspace's "would-be focused" pane,
    // including the current workspace — losing the accent border on
    // the focused pane left the row visually anonymous against the
    // gray source-list highlight, and the dot reads the same way
    // across current and non-current workspaces.
    let isOwnFocus = pane.id == ownFocusPaneId

    titleLabel.stringValue = input.paneTitle(pane)
    iconView.image = input.paneIcon(pane)
    baseIconAlpha = isCurrent ? 1.0 : Self.inactiveIconAlpha
    baseLabelAlpha = isCurrent ? 1.0 : Self.inactiveLabelAlpha

    if isOwnFocus {
      // Brighter dot for the current pane (full accent) and dimmer
      // for non-current workspaces (matches the workspace header's
      // 0.6 alpha de-emphasis on inactive rows).
      let dotColor =
        isCurrent ? accent : accent.withAlphaComponent(0.6)
      focusDot.layer?.backgroundColor = dotColor.cgColor
      focusDot.layer?.cornerRadius = Self.focusDotSize / 2
      focusDot.isHidden = false
    } else {
      focusDot.isHidden = true
    }

    let audio = input.paneAudioState(pane)
    applyAudioState(
      isMuted: audio.isMuted, isPlayingAudio: audio.isPlayingAudio,
      hasActiveMedia: audio.hasActiveMedia)
    applySuspendedState(input.paneIsSuspended(pane))
    applyLoadingState(input.paneIsLoading(pane), accent: accent)

    // Single-pane column (no separate column row) surfaces its column's
    // fold / pin state here; a pane inside a multi-pane column does not
    // (the column row carries it).
    // A `columnNode == nil` pane is the lone pane of a single-pane column,
    // so match on exactly that rather than any column that contains it.
    let ownColumn: ColumnModel? =
      node.columnNode == nil
      ? ws?.model.columns.first(where: { $0.panes.count == 1 && $0.panes.first === pane })
      : nil
    pinIndicator.isHidden = !(ownColumn?.isPinned ?? false)
    foldIndicator.isHidden = !(ownColumn?.isFolded ?? false)

    if let colId = ownColumn?.id {
      onPinToggleHandler = {
        [onAction = input.onColumnAction] in onAction("toggle_pin_column", colId)
      }
      onFoldToggleHandler = {
        [onAction = input.onColumnAction] in onAction("toggle_fold", colId)
      }
    } else {
      onPinToggleHandler = nil
      onFoldToggleHandler = nil
    }

    let paneId = pane.id
    onCloseHandler = {
      [onClose = input.onPaneClose] in onClose(paneId)
    }
    onAudioToggleHandler = {
      [onToggle = input.onPaneAudioToggle] in onToggle(paneId)
    }
  }

  /// Drive the leading-edge speaker glyph from the pane's audio
  /// state. Visible when audio is actually emitting, or when the pane
  /// is muted *and* a media element is still active — the second
  /// branch keeps the unmute affordance on a tab whose audible
  /// playback we just silenced.
  func applyAudioState(
    isMuted: Bool, isPlayingAudio: Bool, hasActiveMedia: Bool
  ) {
    let active = isPlayingAudio || (isMuted && hasActiveMedia)
    audioIndicator.isHidden = !active
    labelLeadingToIcon?.isActive = !active
    labelLeadingToAudio?.isActive = active
    if active {
      let symbol = isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
      let desc = isMuted ? "Unmute pane" : "Mute pane"
      let config = NSImage.SymbolConfiguration(
        pointSize: 10, weight: .regular)
      audioIndicator.image = NSImage(
        systemSymbolName: symbol, accessibilityDescription: desc
      )?.withSymbolConfiguration(config)
      audioIndicator.toolTip = desc
    } else {
      audioIndicator.image = nil
      audioIndicator.toolTip = nil
    }
  }

  /// Swap just the favicon image without reconfiguring the whole row.
  /// Used by the targeted favicon refresh so a fetch-completion post
  /// upgrades the `globe` placeholder in place instead of forcing a
  /// full worklane reload.
  func applyIcon(_ image: NSImage?) {
    iconView.image = image
  }

  /// Toggle the "suspended" affordance: dashed ring around the
  /// favicon plus reduced alpha on icon and title. Alpha is computed
  /// absolutely (`base * mul`) so repeated calls stay idempotent.
  func applySuspendedState(_ isSuspended: Bool) {
    isSuspendedState = isSuspended
    let mul: CGFloat = isSuspended ? Self.suspendedAlpha : 1.0
    iconView.alphaValue = baseIconAlpha * mul
    titleLabel.alphaValue = baseLabelAlpha * mul
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
    layer?.addSublayer(ring)
    suspendedRingLayer = ring
  }

  private func updateSuspendedRingFrame() {
    guard let ring = suspendedRingLayer, isSuspendedState else { return }
    let iconFrame = iconView.frame
    let padding = Self.suspendedRingPadding
    let ringRect = iconFrame.insetBy(dx: -padding, dy: -padding)
    let path = CGPath(ellipseIn: ringRect, transform: nil)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ring.path = path
    ring.frame = bounds
    CATransaction.commit()
  }

  /// Toggle the loading affordance: faint accent halo + bright
  /// rotating arc around the favicon. Mutually exclusive with the
  /// suspended ring — a suspended pane has no live `WKWebView` so it
  /// can't load.
  func applyLoadingState(_ isLoading: Bool, accent: NSColor) {
    isLoadingState = isLoading
    loadingHostView.isHidden = !isLoading
    if isLoading {
      loadingHaloLayer?.strokeColor =
        accent.withAlphaComponent(Self.loadingHaloAlpha).cgColor
      loadingArcLayer?.strokeColor = accent.cgColor
      ensureLoadingRingAnimation()
    } else {
      loadingArcLayer?.removeAllAnimations()
    }
  }

  /// Install the halo + arc layers once at cell setup time so their
  /// geometry never depends on Auto-Layout-resolved frames. Bounds
  /// and the elliptic path are pinned to the host view's intrinsic
  /// size constants — the host's NSView frame may still be `.zero`
  /// before first layout, but the layers render at a fixed 20×20
  /// regardless and inherit the host view's eventual position once
  /// Auto Layout resolves it.
  private func installLoadingLayers() {
    let size = Self.loadingHostSize
    let pathRect = CGRect(x: 0, y: 0, width: size, height: size)
    let path = CGPath(ellipseIn: pathRect, transform: nil)
    let center = CGPoint(x: size / 2, y: size / 2)

    let halo = CAShapeLayer()
    halo.fillColor = nil
    halo.lineWidth = Self.loadingRingLineWidth
    halo.lineCap = .round
    // Full circle baseline so the user sees an anchor even at the
    // instant the arc lands on the gap — also reads as "loading is
    // happening" before progress would otherwise tick.
    halo.strokeStart = 0
    halo.strokeEnd = 1
    halo.path = path
    halo.bounds = pathRect
    halo.position = center
    halo.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    loadingHostView.layer?.addSublayer(halo)
    loadingHaloLayer = halo

    let arc = CAShapeLayer()
    arc.fillColor = nil
    arc.lineWidth = Self.loadingRingLineWidth
    arc.lineCap = .round
    arc.strokeStart = 0
    arc.strokeEnd = Self.loadingArcStrokeEnd
    arc.path = path
    arc.bounds = pathRect
    arc.position = center
    arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    loadingHostView.layer?.addSublayer(arc)
    loadingArcLayer = arc
  }

  private func ensureLoadingRingAnimation() {
    guard let arc = loadingArcLayer,
      arc.animation(forKey: "spin") == nil
    else { return }
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = -CGFloat.pi * 2
    spin.duration = Self.loadingRingRotationDuration
    spin.repeatCount = .infinity
    // `isRemovedOnCompletion = false` keeps the animation running
    // across off-screen / re-attached transitions; AppKit would
    // otherwise drop it when the layer briefly detaches during scroll.
    spin.isRemovedOnCompletion = false
    arc.add(spin, forKey: "spin")
  }

  override func layout() {
    super.layout()
    updateSuspendedRingFrame()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    if let ring = suspendedRingLayer {
      effectiveAppearance.performAsCurrentDrawingAppearance {
        ring.strokeColor = NSColor.tertiaryLabelColor.cgColor
      }
    }
    // Loading ring uses the workspace accent (passed at apply time),
    // which is appearance-independent — nothing to re-resolve here.
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
  }

  override func mouseEntered(with _: NSEvent) {
    setHovered(true)
  }

  override func mouseExited(with _: NSEvent) {
    if cursorIsStillInsideBounds() { return }
    setHovered(false)
  }

  private func setHovered(_ hovered: Bool) {
    guard hovered != isHovered else { return }
    isHovered = hovered
    closeButton.setRevealed(hovered)
    // Selection highlight still wins visually when both apply.
    layer?.backgroundColor =
      hovered ? AppColors.hoverOverlay.cgColor : nil
    layer?.cornerRadius = hovered ? 4 : 0
  }

  @objc private func closeTapped(_: NSButton) {
    onCloseHandler?()
  }

  @objc private func audioTapped(_: NSButton) {
    onAudioToggleHandler?()
  }

  @objc private func pinTapped(_: NSButton) { onPinToggleHandler?() }
  @objc private func foldTapped(_: NSButton) { onFoldToggleHandler?() }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
