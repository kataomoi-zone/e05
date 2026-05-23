import AppKit

/// Top 36pt strip inside the sidebar overlay. The left portion sits
/// under the OS traffic lights (which stay at their default position
/// thanks to `titlebarAppearsTransparent`); the trailing edge hosts the
/// pin toggle button. Click invokes `onTogglePin`, which the view
/// controller routes into the `SidebarState` machine.
///
/// Workspace / pane creation entry points used to live next to the
/// pin button as a `+` menu, but they only make sense while the
/// worklane mode is showing — the worklane footer row hosts the
/// workspace ones and each workspace row's chevron split-menu
/// hosts the pane ones now.
@MainActor
final class SidebarHeaderView: NSView {
  static let height: CGFloat = 36

  /// Gap between the rightmost traffic-light button and the title.
  private static let trafficLightGap: CGFloat = 8

  /// Used when no window is attached (test harness, headless build).
  /// Measured on macOS 26 (Tahoe) where the standard close/min/zoom
  /// cluster occupies ~70pt.
  private static let fallbackTrafficLightInset: CGFloat = 78

  /// Updated in `viewDidMoveToWindow` once the standard window
  /// buttons can be measured.
  private var titleLeadingConstraint: NSLayoutConstraint?

  let pinButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    return b
  }()

  private let titleLabel: TitleLabel = {
    let label = TitleLabel(labelWithString: SidebarHeaderView.displayTitle())
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 11, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.drawsBackground = false
    return label
  }()

  private static func displayTitle() -> String {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    if let version, !version.isEmpty {
      return "E05 \(version)"
    }
    return "E05"
  }

  /// Pass-through label that returns nil from `hitTest` so the parent
  /// `SidebarHeaderView` receives the mouseDown — which then routes
  /// into the OS window-drag pipeline via the explicit `performDrag`
  /// call in `mouseDown(with:)` below. Without this, clicks on the
  /// visible title glyphs would land on the NSTextField itself
  /// (whose default mouseDown does nothing useful for drag) and the
  /// user couldn't drag the window from the title text.
  ///
  /// NOTE: nil-hitTest forfeits text selection. The label is built
  /// with `labelWithString:` which is non-selectable by default, so
  /// this is fine. If the label is ever made selectable (e.g. to
  /// let the user copy the version string), wrap the text view in
  /// a drag-handle parent instead so the text view keeps its own
  /// hit region.
  private final class TitleLabel: NSTextField {
    override func hitTest(_: NSPoint) -> NSView? { nil }
  }

  /// Invoked when the user clicks the pin toggle. The view controller
  /// owns the state machine — this view only reports intent.
  var onTogglePin: (() -> Void)?

  /// Drives the pin icon glyph and accessibility text. When `true`,
  /// the filled pin emphasises the "currently pinned" state; when
  /// `false`, the outline pin signals the action the click will take
  /// (pin the sidebar).
  var isPinned: Bool = false {
    didSet { updatePinAppearance() }
  }

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    setupLayout()
    updatePinAppearance()
  }

  /// Restore the window-drag handle that the URL bar's hover-reveal
  /// took away. With the URL bar hidden by default, the only chrome
  /// the user can grab to reposition the window is this header
  /// strip (the rest of the surface area belongs to a WKWebView, a
  /// terminal, or a finder pane — none of which let click events
  /// fall through to the OS drag handler).
  ///
  /// We route through `performDrag(with:)` rather than relying on
  /// `mouseDownCanMoveWindow`. The latter walks back up the responder
  /// chain, but `SidebarOverlayView` (this view's grandparent through
  /// the `NSGlassEffectView` content path) installs an empty
  /// `mouseDown` override that absorbs clicks to keep transparent
  /// gaps from passing through to the workspace pane behind. That
  /// absorber takes the window-drag attribute path with it, so
  /// AppKit never sees a willing handler. Calling `performDrag`
  /// explicitly bypasses the chain. Clicks on the pin button still
  /// land on `pinButton` first (NSButton overrides `mouseDown`),
  /// and the title label routes through `TitleLabel`'s nil
  /// `hitTest` so clicks on the glyphs reach this view.
  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }

  /// Reclaim the empty leading strip (the 78pt traffic-light inset
  /// before the title) as part of the drag handle. `SidebarOverlayView`
  /// installs a `hitTest` that returns itself for any in-bounds point,
  /// so transparent regions of the header would otherwise route to
  /// the overlay's no-op mouseDown instead of this view. Returning
  /// `self` for points the regular hit chain doesn't claim keeps the
  /// pin button's hit (a real subview) intact while making the entire
  /// strip — including the gap between the traffic lights and the
  /// title glyphs — feel like a single contiguous drag surface.
  override func hitTest(_ point: NSPoint) -> NSView? {
    if let hit = super.hitTest(point), hit !== self { return hit }
    let local = convert(point, from: superview)
    return bounds.contains(local) ? self : nil
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    pinButton.target = self
    pinButton.action = #selector(pinTapped(_:))
    addSubview(pinButton)
    addSubview(titleLabel)

    let leading = titleLabel.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: Self.fallbackTrafficLightInset)
    titleLeadingConstraint = leading
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      pinButton.widthAnchor.constraint(equalToConstant: 22),
      pinButton.heightAnchor.constraint(equalToConstant: 22),
      leading,
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pinButton.leadingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  /// Update the title's leading inset from the live traffic-light
  /// cluster width once a window is attached. The static fallback
  /// (78pt, macOS 26 Tahoe measurement) is fine for the static
  /// initial layout but desyncs on OS versions that change the
  /// cluster geometry — `.zoomButton.frame.maxX` reads the actual
  /// right edge whatever the cluster looks like today.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let zoom = window?.standardWindowButton(.zoomButton) else { return }
    titleLeadingConstraint?.constant = zoom.frame.maxX + Self.trafficLightGap
  }

  private func updatePinAppearance() {
    let symbol = isPinned ? "pin.fill" : "pin"
    let description = isPinned ? "Unpin sidebar" : "Pin sidebar"
    pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    pinButton.toolTip = description
  }

  @objc private func pinTapped(_: NSButton) {
    onTogglePin?()
  }
}
