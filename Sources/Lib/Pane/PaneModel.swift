import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "PaneModel")

/// Preset for pane width. Each cycle action defines an ordered list of these.
public enum PaneWidthPreset: Equatable {
  case columns(Int)
  case fraction(CGFloat)
}

/// The content type of a pane.
public enum PaneContent {
  case terminal(GhosttyTerminalView)
  case browser(BrowserPaneView)
}

/// A single pane within a column — either a terminal or a browser.
@MainActor
public final class PaneModel {
  public let id = ULID()
  public var address: PaneAddress
  public private(set) var content: PaneContent

  /// Terminal title or page title.
  public var title: String = ""

  /// Overlay header showing the title (visible when URL bar is hidden).
  public let headerView = PaneHeaderView()

  /// Shared URL bar (toggleable, visible on all pane types).
  public let urlBar = PaneURLBar()

  /// Per-pane find bar. Sits in the constraint hierarchy directly
  /// below the URL bar so the content view is pushed down when the
  /// bar reveals, and so horizontal scrolling / pane moves carry the
  /// bar along with the pane instead of stranding it over window-
  /// absolute coordinates.
  public let findBar = FindBarView()

  /// Whether the URL bar is currently shown.
  public private(set) var isURLBarVisible = false

  /// Whether the find bar is currently revealed. Controlled through
  /// `setFindBarVisible(_:)`, which toggles both `findBar.isHidden`
  /// and the height constraint so collapsed bars don't occupy layout.
  public private(set) var isFindBarVisible = false

  // TODO: used for vertical drag resize (Step 5)
  public var heightConstraint: NSLayoutConstraint?

  /// Container view holding URL bar + content. This is what gets added to the layout.
  public let containerView: NSView = {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()

  /// The raw content NSView (terminal / browser).
  public var rawContentView: NSView {
    switch content {
    case .terminal(let tv): return tv
    case .browser(let bv): return bv
    }
  }

  /// Convenience: returns GhosttyTerminalView if this is a terminal pane.
  public var terminalView: GhosttyTerminalView? {
    if case .terminal(let tv) = content { return tv }
    return nil
  }

  /// Convenience: returns BrowserPaneView if this is a browser pane.
  public var browserView: BrowserPaneView? {
    if case .browser(let bv) = content { return bv }
    return nil
  }

  /// The pane's find-in-page driver. Both `BrowserPaneView` and
  /// `GhosttyTerminalView` conform to `FindHelper`, so the shared
  /// find-bar controller can treat the two pane kinds uniformly
  /// instead of branching on content. An exhaustive switch here
  /// means adding a new `PaneContent` case forces a compiler error
  /// on the missing find strategy.
  public var findHelper: FindHelper? {
    switch content {
    case .browser(let v): return v
    case .terminal(let v): return v
    }
  }

  /// Whether this is a blank browser pane (no URL loaded yet).
  public var isBlankBrowser: Bool {
    address == .blankBrowser
  }

  /// The view that should become first responder when this pane is focused.
  public var preferredFirstResponder: NSView {
    switch content {
    case .terminal(let tv): return tv
    case .browser(let bv): return bv.webView
    }
  }

  private var urlBarTopConstraint: NSLayoutConstraint?
  /// Content-top constraint used while the URL bar is visible. Anchors
  /// to `findBar.bottom` rather than `urlBar.bottom`: when the find
  /// bar is hidden its height constraint collapses to zero, so the
  /// two anchor points coincide and the find-hidden case lays out
  /// identically to the original design.
  private var contentTopBelowBarsConstraint: NSLayoutConstraint?
  private var contentTopToContainerConstraint: NSLayoutConstraint?
  private var findBarHeightConstraint: NSLayoutConstraint?

  /// Create a pane from a PaneAddress. Routes to the appropriate content type.
  ///
  /// `ghosttyApp` is optional so browser-only callers and tests can omit
  /// it; the terminal branch asserts it when needed. Unknown kinds (e.g.
  /// a session entry pointing at a retired `e05://history` URL) fall
  /// back to a blank browser so old sessions still load without crashing.
  public init(address: PaneAddress, ghosttyApp: GhosttyApp?) {
    self.address = address
    switch address.kind {
    case .terminal:
      guard let ghosttyApp else { fatalError("GhosttyApp required for terminal pane") }
      let tv = GhosttyTerminalView(frame: .zero, ghosttyApp: ghosttyApp)
      tv.translatesAutoresizingMaskIntoConstraints = false
      self.content = .terminal(tv)
    case .browser:
      let bv = Self.makeBrowserView()
      self.content = .browser(bv)
    case .settings:
      // Settings is planned but not yet implemented. Log and fall
      // back to a blank browser so users who type `e05://settings`
      // or restore a session referencing it see an empty pane
      // instead of a debug-build trap. The feature remains on the
      // roadmap — drop this branch once a real Settings view ships.
      logger.warning(
        "Settings pane is not yet implemented — falling back to blank browser"
      )
      let bv = Self.makeBrowserView()
      self.content = .browser(bv)
    case .unknown:
      // Retired special-pane addresses (legacy `e05://history` etc.)
      // and anything else that doesn't map to a known kind land here.
      // Surface via the logger so stale session entries are visible
      // during development, and fall back to a blank browser so the
      // surrounding session restore path still completes.
      //
      // `privacy: .public` is intentional: the inputs reaching this
      // branch are filtered by `PaneAddress.fromUserInput`'s allowlist
      // (https / http / e05 / about), so nothing more sensitive than
      // URLs a developer could have typed into the URL bar or that
      // already live in the on-disk session file flows through. Being
      // able to read them in Console.app during development is the
      // whole point of the warning.
      logger.warning(
        "Unknown pane address \(address.description, privacy: .public) — falling back to blank browser"
      )
      let bv = Self.makeBrowserView()
      self.content = .browser(bv)
    }
    setupContainerView()
    if case .browser(let bv) = content, address.kind == .browser,
      !isBlankBrowser
    {
      bv.navigate(to: address.url.absoluteString)
    }
  }

  private static func makeBrowserView() -> BrowserPaneView {
    let bv = BrowserPaneView()
    bv.translatesAutoresizingMaskIntoConstraints = false
    return bv
  }

  // MARK: - Container Layout

  private func setupContainerView() {
    let cv = rawContentView
    urlBar.translatesAutoresizingMaskIntoConstraints = false
    findBar.translatesAutoresizingMaskIntoConstraints = false
    headerView.translatesAutoresizingMaskIntoConstraints = false

    // Start both bars collapsed so a freshly created pane doesn't
    // flash an empty strip before `applyURLBarVisibility` settles
    // the real state.
    findBar.isHidden = true

    containerView.addSubview(urlBar)
    containerView.addSubview(findBar)
    containerView.addSubview(cv)
    containerView.addSubview(headerView)

    // URL bar at top
    urlBarTopConstraint = urlBar.topAnchor.constraint(equalTo: containerView.topAnchor)
    let urlBarHeight = urlBar.heightAnchor.constraint(equalToConstant: PaneURLBar.barHeight)

    // Find bar directly below the URL bar. Height collapses to 0
    // while hidden so the content view is flush with the URL bar;
    // `setFindBarVisible(true)` swaps the constant to
    // `FindBarView.barHeight`, pushing the page down by one row.
    let findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
    findBarHeightConstraint = findBarHeight

    // Content: below the find bar when the URL bar is visible, or at
    // the container top when the URL bar is hidden (the find bar can
    // only be revealed alongside the URL bar, so no hidden-URL+
    // visible-find combination reaches layout).
    contentTopBelowBarsConstraint = cv.topAnchor.constraint(equalTo: findBar.bottomAnchor)
    contentTopToContainerConstraint = cv.topAnchor.constraint(equalTo: containerView.topAnchor)

    NSLayoutConstraint.activate([
      urlBarTopConstraint!,
      urlBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      urlBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      urlBarHeight,

      findBar.topAnchor.constraint(equalTo: urlBar.bottomAnchor),
      findBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      findBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      findBarHeight,

      cv.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      cv.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      cv.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

      // Header overlay (top-right, only shown when URL bar is hidden)
      headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      headerView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
      headerView.heightAnchor.constraint(equalToConstant: 22),
      headerView.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
    ])

    containerView.wantsLayer = true
    containerView.layer?.cornerRadius = 12
    containerView.layer?.cornerCurve = .continuous
    containerView.layer?.masksToBounds = true

    // Start with URL bar hidden
    applyURLBarVisibility()
    urlBar.setDisplayURL(isBlankBrowser ? "" : address.description)
  }

  // MARK: - URL Bar Toggle

  public func setURLBarVisible(_ visible: Bool) {
    guard visible != isURLBarVisible else { return }
    isURLBarVisible = visible
    applyURLBarVisibility()
  }

  private func applyURLBarVisibility() {
    urlBar.isHidden = !isURLBarVisible
    // Deactivate first to avoid conflicting constraints
    if isURLBarVisible {
      contentTopToContainerConstraint?.isActive = false
      contentTopBelowBarsConstraint?.isActive = true
    } else {
      contentTopBelowBarsConstraint?.isActive = false
      contentTopToContainerConstraint?.isActive = true
    }
  }

  // MARK: - Find Bar Toggle

  /// Reveal or hide the find bar. The bar sits in the constraint
  /// hierarchy directly below the URL bar; revealing it pushes the
  /// content view down by `FindBarView.barHeight`, hiding collapses
  /// the strip to zero height so layout matches the bar-less default.
  ///
  /// Panes without a `findHelper` ignore the call so an external
  /// caller can't unfurl a bar over a surface that has no search
  /// engine wired up.
  public func setFindBarVisible(_ visible: Bool) {
    guard findHelper != nil else { return }
    guard visible != isFindBarVisible else { return }
    isFindBarVisible = visible
    findBar.isHidden = !visible
    findBarHeightConstraint?.constant = visible ? FindBarView.barHeight : 0
  }
}
