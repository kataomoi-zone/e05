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

  private let iconView = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let focusDot = NSView()
  private static let focusDotSize: CGFloat = 6
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

  init(
    paneId: ULID, title: String, icon: NSImage?, accentColor: NSColor,
    isCurrent: Bool, isOwnWorkspaceFocus: Bool, isPrivate: Bool
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

      label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
      label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      closeButton.widthAnchor.constraint(equalToConstant: 16),
      closeButton.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  private func configure(
    title: String, icon: NSImage?, accentColor: NSColor,
    isCurrent: Bool, isOwnWorkspaceFocus: Bool, isPrivate: Bool
  ) {
    isCurrentPane = isCurrent
    label.stringValue = title
    label.alphaValue = isCurrent ? 1.0 : 0.8
    iconView.image = icon
    iconView.alphaValue = isCurrent ? 1.0 : 0.75
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
      isHovered ? NSColor(white: 1.0, alpha: 0.08).cgColor : nil
    layer?.cornerRadius = isHovered ? 4 : 0
  }

  override func mouseDown(with _: NSEvent) {
    onClick?()
  }

  @objc private func closeTapped(_: NSButton) {
    onClose?()
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }
}
