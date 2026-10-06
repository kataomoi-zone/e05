import AppKit

/// NSButton subclass that tints its background subtly while hovered:
/// a circle on a square button, a pill otherwise, drawn around the
/// glyph's own centre.
@MainActor
public final class HoverIconButton: NSButton {
  public override class var cellClass: AnyClass? {
    get { CenteredGlyphCell.self }
    set {}
  }

  private var trackingArea: NSTrackingArea?
  private var isHovering = false {
    didSet { updateHoverAppearance() }
  }

  /// Where the glyph's ink lies within `image`; the cell centres on
  /// it. Measured as the image is set, not while drawing: a render
  /// into a scratch bitmap from inside a draw pass comes out wrong.
  fileprivate private(set) var glyphInk: NSRect?

  public override var image: NSImage? {
    didSet { glyphInk = image.flatMap(Self.ink(of:)) }
  }

  public override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// An 11pt symbol in an 18pt circle: how every sidebar list draws
  /// its rows' buttons and indicators, and the worklane footer its
  /// buttons.
  public static func sidebarIcon(_ symbol: String, description: String) -> HoverIconButton {
    let button = HoverIconButton()
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
      .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    button.toolTip = description
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: 18),
      button.heightAnchor.constraint(equalToConstant: 18),
    ])
    return button
  }

  /// Auto Layout sizes a button by its alignment rect, which `NSButton`
  /// draws from the glyph's text alignment box, so an 18pt constraint
  /// gave a frame up to 25pt tall with the glyph off its centre. The
  /// frame is the button: the hover tint fills it and the glyph is
  /// centred in it.
  public override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

  public override var isEnabled: Bool {
    didSet {
      // Clear stale hover state if the button becomes disabled while hovered,
      // so the tint doesn't linger until the next mouseExited.
      if !isEnabled { isHovering = false }
    }
  }

  public override func layout() {
    super.layout()
    layer?.cornerRadius = min(bounds.width, bounds.height) / 2
  }

  public override func updateTrackingAreas() {
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

  public override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    isHovering = isEnabled
  }

  public override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    isHovering = false
  }

  private func updateHoverAppearance() {
    layer?.backgroundColor =
      isHovering
      ? AppColors.buttonHoverOverlay.cgColor(under: effectiveAppearance)
      : nil
  }

  /// Show / hide a hover-revealed button without using `isHidden`.
  /// Flipping `isHidden` rebuilds the surrounding tracking areas,
  /// which makes the cell-level `mouseExited` fire mid-rebuild and
  /// drops the row hover before the cursor reaches the button.
  /// Alpha + `isEnabled` keep geometry constant.
  public func setRevealed(_ revealed: Bool) {
    alphaValue = revealed ? 1 : 0
    isEnabled = revealed
  }
}

/// `NSButtonCell` centres a symbol's alignment rect, the box a line of
/// text would sit on, and the ink lands up to half a point off the
/// centre of a small square button. Inside a circle that reads as
/// crooked. Centre the ink instead.
@MainActor
private final class CenteredGlyphCell: NSButtonCell {
  override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
    let align = image.alignmentRect
    // Only the layout this correction was measured for: the image at
    // its own size, alone in a flipped button.
    guard imagePosition == .imageOnly, controlView.isFlipped,
      abs(frame.width - align.width) < 0.5, abs(frame.height - align.height) < 0.5,
      let ink = (controlView as? HoverIconButton)?.glyphInk
    else {
      return super.drawImage(image, withFrame: frame, in: controlView)
    }
    // AppKit fills `frame` with the alignment rect; the image's top-left
    // follows from that.
    let imageOrigin = NSPoint(
      x: frame.minX - align.minX, y: frame.maxY + align.minY - image.size.height)
    let inkCenter = NSPoint(x: imageOrigin.x + ink.midX, y: imageOrigin.y + ink.midY)
    let bounds = controlView.bounds
    // Not snapped to any grid: AppKit rounds the origin to whole points
    // itself, and a half-point nudge here only moves it the wrong way.
    let centered = NSRect(
      x: frame.minX + bounds.midX - inkCenter.x,
      y: frame.minY + bounds.midY - inkCenter.y,
      width: frame.width, height: frame.height)
    super.drawImage(image, withFrame: centered, in: controlView)
  }
}

extension HoverIconButton {
  /// The glyph's own bounds within `image`, in points from its
  /// top-left corner, read off a render of it. A full-colour icon is
  /// its own ink and needs no measuring.
  fileprivate static func ink(of image: NSImage) -> NSRect? {
    guard image.isTemplate else { return nil }
    let scale = 2
    let width = Int(image.size.width.rounded(.up))
    let height = Int(image.size.height.rounded(.up))
    guard width > 0, height > 0,
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    // The point size has to be in place before the context reads it.
    rep.size = NSSize(width: width, height: height)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    // At the image's own size, so a fractional size is not stretched
    // to the bitmap's whole points.
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return inkBounds(in: rep)
  }

  /// The bounds of what was drawn into `rep`, in points from its
  /// top-left corner.
  static func inkBounds(in rep: NSBitmapImageRep) -> NSRect? {
    guard let data = rep.bitmapData, rep.samplesPerPixel == 4, rep.bitsPerSample == 8 else {
      return nil
    }
    let row = rep.bytesPerRow
    var minX = Int.max
    var minY = Int.max
    var maxX = -1
    var maxY = -1
    for y in 0..<rep.pixelsHigh {
      for x in 0..<rep.pixelsWide where data[y * row + x * 4 + 3] > 25 {
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
      }
    }
    guard maxX >= 0 else { return nil }
    let s = CGFloat(rep.pixelsWide) / rep.size.width
    return NSRect(
      x: CGFloat(minX) / s, y: CGFloat(minY) / s,
      width: CGFloat(maxX - minX + 1) / s, height: CGFloat(maxY - minY + 1) / s)
  }
}
