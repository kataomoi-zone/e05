import AppKit

/// Bottom navigation strip in the sidebar. Lays one icon-only button
/// per `SidebarMode` (Tabs / Bookmarks / History / Downloads /
/// Extensions) into a single equal-width row. Clicking a button
/// invokes `onSelect`, which the sidebar view controller uses to
/// swap the mode area's content. The Downloads button exposes a
/// pill-shaped active-count badge overlaid on the icon's top-right
/// corner; the badge is hidden when the count is zero.
///
/// Labels live as `toolTip` and accessibility values rather than as
/// inline text so the strip stays compact enough to free vertical
/// space for the worklane and bookmarks/history lists above.
@MainActor
final class PlacesSectionView: NSView {
  /// Fired when the user selects a mode by clicking its button.
  var onSelect: ((SidebarMode) -> Void)?

  private let stack = NSStackView()
  private let indicator = SelectionIndicator()
  private var buttons: [SidebarMode: PlacesButton] = [:]
  /// The mode the indicator is currently anchored to. Tracked
  /// separately from the per-button `isSelected` flag so layout
  /// passes (window resize, sidebar pin transition) can re-pin the
  /// indicator's frame without animation when the geometry shifts
  /// underneath it.
  private var currentMode: SidebarMode?

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    // Indicator goes in first so it sits beneath the buttons in
    // z-order — the icons render over its tint, the way iPadOS's
    // Liquid Glass tab bar layers its selection capsule. Hidden
    // until `setCurrentMode` runs the first time so the chip
    // doesn't paint at the origin before its target frame is
    // resolved.
    indicator.isHidden = true
    addSubview(indicator)

    stack.orientation = .horizontal
    stack.spacing = 4
    stack.alignment = .centerY
    stack.distribution = .fillEqually
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: PlacesButton.height),
    ])
    for mode in SidebarMode.allCases {
      let button = PlacesButton(mode: mode)
      button.onClick = { [weak self] in self?.onSelect?(mode) }
      stack.addArrangedSubview(button)
      buttons[mode] = button
    }
  }

  override func layout() {
    super.layout()
    // Resync the indicator after AutoLayout finishes — the buttons'
    // frames aren't valid until the equal-distribution pass runs, so
    // the first paint and any width change (sidebar pin/unpin) need
    // a fresh, animation-free pin.
    syncIndicatorFrame(animated: false)
  }

  /// Highlight the current mode's button; clear the others.
  func setCurrentMode(_ mode: SidebarMode) {
    let isFirstSelection = currentMode == nil
    let modeChanged = currentMode != mode
    currentMode = mode
    for (buttonMode, button) in buttons {
      button.setSelected(buttonMode == mode)
    }
    // Reveal the indicator the first time we ever pick a mode (no
    // tween — it would slide in from the origin), then animate
    // every subsequent move so a click reads as the highlight
    // gliding to its new home rather than teleporting.
    if isFirstSelection {
      indicator.isHidden = false
      syncIndicatorFrame(animated: false)
    } else if modeChanged {
      syncIndicatorFrame(animated: true)
    }
  }

  /// Update the Downloads button badge. A count of zero hides the badge.
  func setDownloadsBadge(count: Int) {
    buttons[.downloads]?.setBadge(count: count)
  }

  /// Move the indicator's frame to the currently selected button.
  /// `animated == false` snaps for layout-driven calls (initial
  /// layout, sidebar resize); `animated == true` runs a short tween
  /// for explicit user-driven mode changes.
  private func syncIndicatorFrame(animated: Bool) {
    guard let mode = currentMode, let target = buttons[mode] else { return }
    let targetFrame = convert(target.bounds, from: target)
    guard !targetFrame.isEmpty else { return }
    if animated {
      NSAnimationContext.runAnimationGroup { ctx in
        // Below ~150ms the slide is short enough to read as a snap,
        // above ~300ms rapid mode-cycling starts to feel sticky.
        ctx.duration = 0.22
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ctx.allowsImplicitAnimation = true
        indicator.animator().frame = targetFrame
      }
    } else {
      indicator.frame = targetFrame
    }
  }

  // Absorb mouse events that land in the gutters between buttons (and
  // in the strip's padding). Without these overrides the click would
  // forward up the responder chain via the `NSResponder` default and
  // leak through `NSGlassEffectView`'s transparent regions to the
  // workspace pane underneath, letting the user click links / select
  // text in the WebView through the sidebar's footer area. Same
  // pattern as `WorklaneOutlineView` in the worklane — `scrollWheel` etc.
  // are intentionally not overridden.
  override func mouseDown(with _: NSEvent) {}
  override func mouseDragged(with _: NSEvent) {}
  override func mouseUp(with _: NSEvent) {}
}

/// One clickable button in `PlacesSectionView`: an icon centered in
/// a tappable square, optionally overlaid with a notification-style
/// badge (used only by the Downloads button). The mode label is
/// surfaced via `toolTip` and `accessibilityLabel` rather than as
/// inline text so the strip can fit five modes inside the sidebar's
/// 260pt width.
@MainActor
private final class PlacesButton: NSView {
  /// Fixed strip height. Combined with `.fillEqually` distribution
  /// in the parent stack, every button ends up the same square-ish
  /// hit target across the row.
  static let height: CGFloat = 36

  let mode: SidebarMode
  var onClick: (() -> Void)?

  private let iconView = NSImageView()
  private let badge = DownloadsBadgeView()
  private var trackingArea: NSTrackingArea?
  private var isHovered = false
  private var isSelected = false

  init(mode: SidebarMode) {
    self.mode = mode
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    toolTip = mode.title
    setAccessibilityRole(.button)
    setAccessibilityLabel(mode.title)
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

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
    isHovered = true
    applyBackground()
  }

  override func mouseExited(with _: NSEvent) {
    isHovered = false
    applyBackground()
  }

  private func setupLayout() {
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = NSImage(
      systemSymbolName: mode.symbolName,
      accessibilityDescription: mode.title
    )
    iconView.imageScaling = .scaleProportionallyDown
    iconView.contentTintColor = .secondaryLabelColor
    addSubview(iconView)

    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.isHidden = true
    addSubview(badge)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),
      // Pin the badge to the icon's top-right corner with a small
      // overlap so it reads as "attached" to the icon rather than
      // floating in the gutter, matching macOS Mail's unread badge.
      badge.centerXAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 2),
      badge.centerYAnchor.constraint(equalTo: iconView.topAnchor, constant: 2),
    ])
  }

  func setSelected(_ selected: Bool) {
    isSelected = selected
    iconView.contentTintColor = selected ? .labelColor : .secondaryLabelColor
    // Surface the active state to VoiceOver. The default
    // `.button` role on a custom NSView doesn't infer selection,
    // so without this users hear "Bookmarks button" for every
    // entry instead of "Bookmarks button, selected".
    setAccessibilitySelected(selected)
    applyBackground()
  }

  /// Resolve `layer.backgroundColor` from the hover state alone —
  /// selection background is owned by `PlacesSectionView`'s shared
  /// indicator so it can slide between buttons. We deliberately
  /// suppress the hover tint while this button is the selected one
  /// so the indicator's own tint reads cleanly without a second
  /// layer stacked on top of it.
  private func applyBackground() {
    let showHover = isHovered && !isSelected
    layer?.backgroundColor =
      showHover ? AppColors.hoverOverlay.cgColor : nil
    layer?.cornerRadius = showHover ? 6 : 0
  }

  func setBadge(count: Int) {
    if count <= 0 {
      badge.isHidden = true
    } else {
      badge.count = count
      badge.isHidden = false
    }
  }

  override func mouseDown(with _: NSEvent) {
    onClick?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}

/// Shared selection chip that slides between mode buttons in
/// `PlacesSectionView`. Owning the selection visual centrally (one
/// view that animates its frame) gets the iPadOS-tab-bar effect of
/// a highlight gliding under the icons, instead of one button
/// fading its background out while the next fades in. Pointer
/// events pass through so clicks still reach whichever button the
/// indicator is currently parked over.
@MainActor
private final class SelectionIndicator: NSView {
  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = AppColors.activeOverlay.cgColor
    layer?.cornerRadius = 6
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AppColors.activeOverlay.cgColor
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  override func hitTest(_: NSPoint) -> NSView? { nil }
}

/// Mail.app-style pill badge showing a numeric count, sized to ride
/// on top of the 18 × 18 mode icon without obscuring it. Height is
/// fixed so the corner radius can form a perfect pill; width grows
/// with the label (min-width equals height for single-digit counts).
/// The accent fill stays opaque so the badge stays legible against
/// either a sidebar gutter or the icon's own contentTintColor.
@MainActor
private final class DownloadsBadgeView: NSView {
  static let height: CGFloat = 13

  var count: Int = 0 {
    didSet { label.stringValue = count > 99 ? "99+" : "\(count)" }
  }

  private let label = NSTextField(labelWithString: "0")

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = NSColor.systemBlue.cgColor
    layer?.cornerRadius = Self.height / 2
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    label.translatesAutoresizingMaskIntoConstraints = false
    // Monospaced digits keep the pill width stable as the count
    // changes (1 → 10 → 99+) without snap-resizing on every tick.
    label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    label.textColor = .labelColor
    label.drawsBackground = false
    label.alignment = .center
    addSubview(label)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      widthAnchor.constraint(greaterThanOrEqualToConstant: Self.height),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
    ])
  }
}
