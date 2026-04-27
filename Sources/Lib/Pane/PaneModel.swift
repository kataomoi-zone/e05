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
  /// Native file-browser pane backed by `FinderPaneView`. Adding new
  /// cases here forces compile errors at every switch site (rawContentView,
  /// preferredFirstResponder, findHelper, init, sidebar display helpers),
  /// so the enum exhaustiveness check works as the implicit checklist
  /// for special-pane introductions.
  case finder(FinderPaneView)
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

  /// Per-pane find bar. A floating pill anchored to the bottom of the
  /// container view, independent of the URL bar so it can be shown
  /// even while the URL bar is hidden. Pane-local layout means
  /// horizontal scrolling and pane moves carry the bar along with the
  /// pane instead of stranding it over window-absolute coordinates.
  public let findBar = FindBarView()

  /// Whether the URL bar is currently shown.
  public private(set) var isURLBarVisible = false

  /// Whether the find bar is currently revealed. Controlled through
  /// `setFindBarVisible(_:)`. The bar is a floating overlay so showing
  /// or hiding it does not change content layout — only `alphaValue`
  /// flips, leaving width/height/anchor constraints permanent.
  public private(set) var isFindBarVisible = false

  // TODO: used for vertical drag resize (Step 5)
  public var heightConstraint: NSLayoutConstraint?

  /// Container view holding URL bar + content. This is what gets added to the layout.
  public let containerView: NSView = {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()

  /// The raw content NSView (terminal / browser / finder).
  public var rawContentView: NSView {
    switch content {
    case .terminal(let tv): return tv
    case .browser(let bv): return bv
    case .finder(let fv): return fv
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

  /// Convenience: returns FinderPaneView if this is a finder pane.
  public var finderView: FinderPaneView? {
    if case .finder(let fv) = content { return fv }
    return nil
  }

  /// The pane's find-in-page driver. Both `BrowserPaneView` and
  /// `GhosttyTerminalView` conform to `FindHelper`, so the shared
  /// find-bar controller can treat the two pane kinds uniformly
  /// instead of branching on content. Finder panes return nil because
  /// their search affordance is row-filtering, not in-page glyph
  /// highlighting; the shared find bar's open guard treats nil as
  /// "no find UI" so ⌘F is silently ignored on finder panes.
  public var findHelper: FindHelper? {
    switch content {
    case .browser(let v): return v
    case .terminal(let v): return v
    case .finder: return nil
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
    case .finder(let fv): return fv.keyboardFocusTarget
    }
  }

  private var urlBarTopConstraint: NSLayoutConstraint?
  /// Content-top constraint used while the URL bar is visible. Anchors
  /// directly to `urlBar.bottom`. The find bar no longer participates
  /// in this stack — it floats over the content as a bottom-anchored
  /// pill, so revealing or hiding it does not push the content view.
  private var contentTopBelowBarsConstraint: NSLayoutConstraint?
  private var contentTopToContainerConstraint: NSLayoutConstraint?

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
    case .finder:
      // Empty path means the bare `e05://finder` URL — substitute the
      // user's home directory and rebuild the address so the URL bar
      // and session persistence reflect the actual cwd. Any non-empty
      // path is taken at face value (file URL) and used directly.
      let path = address.currentPath
      let initialURL: URL
      if path.isEmpty {
        initialURL = FileManager.default.homeDirectoryForCurrentUser
        self.address = PaneAddress.finder(path: initialURL.path(percentEncoded: false))
      } else {
        initialURL = URL(fileURLWithPath: path, isDirectory: true)
      }
      let fv = FinderPaneView(initialURL: initialURL)
      self.content = .finder(fv)
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

    // Start both bars collapsed. URL bar visibility is settled by
    // `applyURLBarVisibility` immediately after layout. The find
    // bar stays in the view hierarchy with `alphaValue = 0` so
    // reveal/hide can fade smoothly through the animator — `isHidden`
    // flips would break any in-flight alpha animation. Hit-testing
    // skips alpha-zero views in `FindBarView` so clicks still pass
    // through to the content beneath the invisible bar.
    findBar.alphaValue = 0

    // Order matters: `addSubview(_:)` appends to the end of the
    // sibling list = topmost in z-order. The find bar floats over the
    // pane content, so it must be added after `cv` to render above
    // the WKWebView / GhosttyTerminalView / FinderPaneView surface.
    containerView.addSubview(urlBar)
    containerView.addSubview(cv)
    containerView.addSubview(findBar)
    containerView.addSubview(headerView)

    // URL bar at top
    urlBarTopConstraint = urlBar.topAnchor.constraint(equalTo: containerView.topAnchor)
    let urlBarHeight = urlBar.heightAnchor.constraint(equalToConstant: PaneURLBar.barHeight)

    // Content: directly below the URL bar when visible, otherwise
    // flush with the container top. The find bar floats over the
    // content as a bottom-anchored pill and never participates in
    // this stack.
    contentTopBelowBarsConstraint = cv.topAnchor.constraint(equalTo: urlBar.bottomAnchor)
    contentTopToContainerConstraint = cv.topAnchor.constraint(equalTo: containerView.topAnchor)

    // Find bar pill is centered horizontally and sits 16pt above the
    // pane bottom. Width is fixed so the layout stays predictable
    // across pane sizes; if a needle ever needs to grow the field
    // beyond this, revisit and switch to a `lessThanOrEqual` width
    // constraint.
    let findBarBottomMargin: CGFloat = 16
    let findBarWidth: CGFloat = 380

    NSLayoutConstraint.activate([
      urlBarTopConstraint!,
      urlBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      urlBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      urlBarHeight,

      findBar.bottomAnchor.constraint(
        equalTo: containerView.bottomAnchor,
        constant: -findBarBottomMargin
      ),
      findBar.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
      findBar.widthAnchor.constraint(equalToConstant: findBarWidth),
      findBar.heightAnchor.constraint(equalToConstant: FindBarView.barHeight),

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
    urlBar.setDisplayURL(isBlankBrowser ? "" : address.displayString)
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

  /// Reveal or hide the find bar with a short alpha fade. The bar
  /// is a bottom-anchored pill independent of the URL bar, so
  /// toggling visibility only flips alpha — anchor and size
  /// constraints are permanent and content layout never shifts.
  /// Hit-testing is alpha-gated in `FindBarView` so the invisible
  /// bar still passes clicks through to the content underneath.
  ///
  /// Panes without a `findHelper` ignore the call so an external
  /// caller can't unfurl a bar over a surface that has no search
  /// engine wired up.
  public func setFindBarVisible(_ visible: Bool) {
    guard findHelper != nil else { return }
    guard visible != isFindBarVisible else { return }
    isFindBarVisible = visible
    let target: CGFloat = visible ? 1.0 : 0.0
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.12
      ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
      ctx.allowsImplicitAnimation = true
      findBar.animator().alphaValue = target
    }
  }
}
