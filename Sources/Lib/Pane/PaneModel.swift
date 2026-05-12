import AppKit
import WebKit
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

  /// Transparent 12pt strip at the pane's top edge. The hover-reveal
  /// machinery activates this on the focused pane only — the sidebar
  /// reuses the same `EdgeHoverHitZoneView` for its leading strip,
  /// and per-pane installs let the next focus change just flip
  /// `isHidden` on two zones rather than tearing one down and
  /// rebuilding it elsewhere. Callbacks are attached separately so
  /// `setupPaneCallbacks` owns the lifecycle. Module-internal
  /// because `EdgeHoverHitZoneView` itself is not public.
  let urlBarTopEdgeHitZone = EdgeHoverHitZoneView()

  /// Per-pane URL bar visibility state. Mutated through
  /// `setURLBarVisible(_:)` for the window-global ⌘⇧L pin toggle
  /// and `setURLBarPeek(_:)` for the hover-reveal scheduler in
  /// `PaneContainerViewController`.
  public var urlBarHoverState: URLBarHoverState = .hidden

  /// Whether the URL bar is currently shown. Computed from the
  /// hover state so visibility has a single source of truth.
  public var isURLBarVisible: Bool { urlBarHoverState.isRevealed }

  /// Whether the find bar is currently revealed. Controlled through
  /// `setFindBarVisible(_:)`. The bar is hosted in a child NSPanel
  /// so showing or hiding it does not change content layout —
  /// `setFindBarVisible(_:)` orders the panel front or out and the
  /// reveal animates the panel's alpha.
  public private(set) var isFindBarVisible = false

  /// Debounce timer for match-count updates driven by typing into
  /// this pane's find bar. Per-pane rather than container-wide so
  /// typing into one pane's bar doesn't invalidate a pending update
  /// for another pane's bar — a real concern under per-pane find
  /// session persistence where multiple bars can be live at once.
  var findCountDebounceTimer: Timer?

  // TODO: wire this into vertical drag resize.
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

  /// The pane's find-in-page driver. All three content kinds
  /// conform to `FindHelper`, so the shared find-bar controller
  /// treats them uniformly instead of branching on content. Browser
  /// / terminal panes highlight glyphs in place and step next/prev;
  /// finder panes narrow the visible row list (filter mode), local
  /// to the current cwd (no system-wide Spotlight).
  public var findHelper: FindHelper? {
    switch content {
    case .browser(let v): return v
    case .terminal(let v): return v
    case .finder(let v): return v
    }
  }

  /// Whether this is a blank browser pane (no URL loaded yet).
  public var isBlankBrowser: Bool {
    address == .blankBrowser
  }

  /// True when this is a browser pane whose `WKWebView` has been
  /// detached — either by an explicit `suspend()` or by being
  /// constructed with `startSuspended: true`. Non-browser panes
  /// always report `false`.
  public var isBrowserSuspended: Bool {
    browserView?.isSuspended ?? false
  }

  /// Bring a suspended browser pane back to a live `WKWebView`,
  /// re-applying its captured `interactionState`. No-op for
  /// non-browser panes and for browser panes that are already live.
  public func restoreIfSuspended() {
    browserView?.restore()
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

  /// Create a pane from a PaneAddress. Routes to the appropriate content type.
  ///
  /// `ghosttyApp` is optional so browser-only callers and tests can omit
  /// it; the terminal branch asserts it when needed. Unknown kinds (e.g.
  /// a session entry pointing at a retired `e05://history` URL) fall
  /// back to a blank browser so old sessions still load without crashing.
  ///
  /// `dataStore` is propagated to `BrowserPaneView` so private workspaces
  /// can isolate cookies / storage from the default profile. Nil keeps
  /// the existing default-store behaviour for normal workspaces.
  ///
  /// `startSuspended` only matters for browser panes. When true, the
  /// pane skips its first navigation and renders the suspend
  /// placeholder; a subsequent `restoreIfSuspended()` (typically from
  /// the focus handler) builds the live web view and loads the URL.
  /// `initialTitle` is plumbed through to both `self.title` and the
  /// placeholder so sidebar / worklane rows have something to render
  /// before the page actually loads; when nil the placeholder falls
  /// back to the URL's host. Both parameters are ignored for
  /// non-browser kinds and for blank / unresolved-extension browsers.
  public init(
    address: PaneAddress, ghosttyApp: GhosttyApp?,
    dataStore: WKWebsiteDataStore? = nil,
    startSuspended: Bool = false,
    initialTitle: String? = nil
  ) {
    self.address = address
    switch address.kind {
    case .terminal:
      guard let ghosttyApp else { fatalError("GhosttyApp required for terminal pane") }
      let tv = GhosttyTerminalView(frame: .zero, ghosttyApp: ghosttyApp)
      tv.translatesAutoresizingMaskIntoConstraints = false
      self.content = .terminal(tv)
    case .browser:
      // Extension-owned URLs (`webkit-extension://<uuid>/...`) need
      // the context's own `webViewConfiguration` — Apple's docs are
      // explicit that a generic config + `webExtensionController`
      // pointer is not enough to load extension resources. Resolve
      // the context up front; if the extension was unloaded between
      // session capture and restore, was hand-typed for an
      // extension that no longer exists, or has been disabled, fall
      // through to a standard browser view that renders an
      // in-pane error page instead of letting `webView.load`
      // surface the failure as a blank pane.
      let isExtensionURL = address.url.scheme == PaneAddress.extensionScheme
      let extensionContext: WKWebExtensionContext? =
        isExtensionURL
        ? ExtensionController.shared.extensionContext(forExtensionURL: address.url)
        : nil
      let bv = Self.makeBrowserView(
        extensionContext: extensionContext, dataStore: dataStore
      )
      self.content = .browser(bv)
      // Track the resolution failure so the post-`setupContainerView`
      // navigation block can render an error page instead of
      // attempting to load an unresolvable extension URL.
      isUnresolvedExtensionURL = isExtensionURL && extensionContext == nil
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
      let bv = Self.makeBrowserView(dataStore: dataStore)
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
      let bv = Self.makeBrowserView(dataStore: dataStore)
      self.content = .browser(bv)
    }
    setupContainerView()
    // Extension actions only make sense on browser panes; terminal /
    // finder panes get the URL field unimpeded by puzzle-piece icons.
    // The fallback browser views built for `.settings` / `.unknown`
    // intentionally stay out of this allowlist — they are transient
    // placeholders, not a stable surface for extensions.
    urlBar.showsExtensionsRow = address.kind == .browser
    if case .browser(let bv) = content, address.kind == .browser,
      !isBlankBrowser
    {
      if isUnresolvedExtensionURL {
        bv.loadExtensionUnavailableError(for: address.url)
      } else if startSuspended {
        // Title is captured before the placeholder render so sidebar
        // worklane rows can show the saved title verbatim instead of
        // flashing the hostname fallback while the pane sits
        // suspended.
        if let initialTitle, !initialTitle.isEmpty {
          self.title = initialTitle
        }
        bv.suspendInitially(url: address.url, title: initialTitle)
      } else {
        bv.navigate(to: address.url.absoluteString)
      }
    }
  }

  /// True when the address points at a `webkit-extension://` URL whose
  /// owning context could not be resolved at init time. The init
  /// branches set this so the post-setup navigation block knows to
  /// render an error page instead of letting WebKit paint a blank
  /// failure. Reset to false for every other pane kind.
  private var isUnresolvedExtensionURL: Bool = false

  private static func makeBrowserView(
    extensionContext: WKWebExtensionContext? = nil,
    dataStore: WKWebsiteDataStore? = nil
  ) -> BrowserPaneView {
    let bv = BrowserPaneView(
      frame: .zero, extensionContext: extensionContext, dataStore: dataStore
    )
    bv.translatesAutoresizingMaskIntoConstraints = false
    return bv
  }

  // MARK: - Container Layout

  private func setupContainerView() {
    let cv = rawContentView
    urlBar.translatesAutoresizingMaskIntoConstraints = false
    headerView.translatesAutoresizingMaskIntoConstraints = false

    // The URL bar is a floating overlay driven by `alphaValue` over
    // the pane's top edge. `cv` always spans the full container, so
    // peek / pinned / hidden transitions never shift content layout.
    // Click pass-through is alpha-gated in `PaneURLBar.hitTest` so
    // an invisible bar leaves the page beneath fully interactive.
    // The find bar lives in a child NSPanel managed by
    // `FindBarView.show(anchoredTo:)` and isn't part of this view
    // tree.
    urlBar.alphaValue = 0

    // Top-edge hit zone is hidden until this pane gains focus —
    // unfocused panes don't react to hover, so AppKit doesn't even
    // need to install their tracking areas.
    urlBarTopEdgeHitZone.isHidden = true

    // Order matters: `addSubview(_:)` appends to the end of the
    // sibling list = topmost in z-order. `cv` goes in first so
    // every other view paints over it. The URL bar is a floating
    // overlay. The hit zone sits above the URL bar chrome so its
    // tracking strip stays reachable while the bar is invisible;
    // the hover scheduler bails when the bar is already visible,
    // so the overlapping case is handled in code rather than by
    // shuffling z-order at runtime.
    containerView.addSubview(cv)
    containerView.addSubview(urlBar)
    containerView.addSubview(urlBarTopEdgeHitZone)
    containerView.addSubview(headerView)

    urlBarTopConstraint = urlBar.topAnchor.constraint(equalTo: containerView.topAnchor)
    let urlBarHeight = urlBar.heightAnchor.constraint(equalToConstant: PaneURLBar.barHeight)

    NSLayoutConstraint.activate([
      urlBarTopConstraint!,
      urlBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      urlBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      urlBarHeight,

      // `cv` always spans the full container — URL bar visibility
      // never moves the page content.
      cv.topAnchor.constraint(equalTo: containerView.topAnchor),
      cv.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      cv.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      cv.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

      // Top-edge hit zone spans the pane's full width. Height is
      // owned by `EdgeHoverHitZoneView.topEdgeHeight` so any future
      // tuning stays alongside the strip's other geometry.
      urlBarTopEdgeHitZone.topAnchor.constraint(equalTo: containerView.topAnchor),
      urlBarTopEdgeHitZone.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      urlBarTopEdgeHitZone.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      urlBarTopEdgeHitZone.heightAnchor.constraint(equalToConstant: EdgeHoverHitZoneView.topEdgeHeight),

      // Header overlay (top-right, only shown when URL bar is hidden)
      headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
      headerView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
      headerView.heightAnchor.constraint(equalToConstant: 22),
      headerView.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
    ])

    containerView.wantsLayer = true
    containerView.layer?.cornerRadius = AppMetrics.surfaceCornerRadius
    containerView.layer?.cornerCurve = .continuous
    containerView.layer?.masksToBounds = true

    applyURLBarVisibility(animated: false)
    urlBar.setDisplayURL(isBlankBrowser ? "" : address.displayString)
  }

  // MARK: - URL Bar Toggle

  /// Apply the window-global URL bar toggle to this pane: `true`
  /// pins the bar open, `false` collapses it. Any active `.peek`
  /// reveal is overwritten — when the user pins everything, the
  /// transient peek session ends.
  public func setURLBarVisible(_ visible: Bool) {
    let target: URLBarHoverState = visible ? .pinned : .hidden
    guard target != urlBarHoverState else { return }
    urlBarHoverState = target
    applyURLBarVisibility()
  }

  /// Activate or release a peek reveal — the temporary on-pane URL
  /// bar driven by ⌘L while the global toggle is off.
  ///
  /// `setURLBarPeek(true)` only opens the peek when the bar isn't
  /// already pinned globally; pinning wins, so peek is a no-op
  /// during a pinned session. `setURLBarPeek(false)` only releases
  /// a `.peek` state — a globally-pinned bar is owned by
  /// `setURLBarVisible(_:)` and must not be collapsed by the peek
  /// lifecycle (Esc / committed navigation).
  public func setURLBarPeek(_ active: Bool) {
    let target: URLBarHoverState
    if active {
      // Only `.hidden` enters `.peek`. `.pinned` wins (the global
      // toggle owns it), and `.peek → .peek` is already settled.
      guard urlBarHoverState == .hidden else { return }
      target = .peek
    } else {
      // Only release our own `.peek`. `.pinned` belongs to
      // `setURLBarVisible(_:)`; `.hidden` is already settled.
      guard urlBarHoverState == .peek else { return }
      target = .hidden
    }
    urlBarHoverState = target
    applyURLBarVisibility()
  }

  private func applyURLBarVisibility(animated: Bool = true) {
    // Cross-fade the bar over 120ms — the same cadence as the find
    // bar so the two chrome elements feel like siblings. The bar is
    // a floating overlay anchored to the pane's top edge, so neither
    // alpha nor opacity animation ever shifts the content beneath.
    // `PaneURLBar.hitTest` skips alpha-zero bars so clicks fall
    // through to the page when the bar is invisible.
    //
    // `animated: false` is for the initial pane build, where the
    // freshly-allocated `PaneURLBar` is still at its default 1.0
    // alpha and a fade-from-visible would briefly flash the bar
    // before settling at hidden.
    let target: CGFloat = isURLBarVisible ? 1 : 0
    if isURLBarVisible {
      // Probe the cursor before the alpha animation starts. AppKit's
      // tracking area only fires `mouseEntered` on a fresh entry,
      // and the cursor is typically already inside the bar's bounds
      // when peek opens (the user just hovered the top-edge hit
      // zone, which sits within the URL bar's 28pt rect). Without
      // this probe, the host's hover-out timer that the hit zone
      // exit just scheduled would never get cancelled.
      urlBar.syncHoverWithCurrentCursor()
    }
    if animated {
      // Drop any in-flight alpha animation before queuing a new one.
      // Without this, a fast hidden → peek → hidden flick layers two
      // 120ms tweens on top of each other and the presentation alpha
      // briefly walks backward through the previous animation's
      // remaining frames before settling — which also fluttters the
      // `hitTest` alpha gate (`> 0.01`) on/off and causes click
      // pass-through to flicker against the page beneath.
      urlBar.layer?.removeAnimation(forKey: "opacity")
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.12
        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ctx.allowsImplicitAnimation = true
        urlBar.animator().alphaValue = target
      }
    } else {
      urlBar.layer?.removeAnimation(forKey: "opacity")
      urlBar.alphaValue = target
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
    if visible {
      findBar.show(anchoredTo: containerView)
    } else {
      findBar.hide()
    }
  }
}
