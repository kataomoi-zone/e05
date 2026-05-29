import AppKit
import WebKit
import os.log

private let logger = Logger(
  subsystem: LogSubsystem.app, category: "BrowserPaneView")

/// WKWebView subclass that reports focus changes via callback.
@MainActor
final class FocusReportingWebView: WKWebView {
  var onFocusGained: (() -> Void)?

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    // Covers click and tab navigation. Click on already-focused webView
    // doesn't fire this, but the pane is already focused in that case.
    if result { onFocusGained?() }
    return result
  }
}

/// Browser pane wrapping a WKWebView. Hosts the Web Inspector inline when attached.
///
/// Layout structure:
/// - BrowserPaneView (Auto Layout)
///   └── browserHostView (manual frames — WebKit manages WKWebView + Inspector sizes)
///       ├── webView
///       └── Inspector (added by WebKit when attached)
///
/// The browserHostView is required because WebKit manipulates frames directly when
/// Inspector is attached. Using Auto Layout on webView would conflict with this.
@MainActor
public final class BrowserPaneView: NSView, WKNavigationDelegate, WKUIDelegate {
  /// The active web view, rebuilt by `restore()` after a `suspend()`
  /// dropped the previous instance. Callers can hold the reference
  /// across a single navigation but must re-read it after any
  /// suspend/restore round-trip — the old `WKWebView` is detached
  /// and the new one carries the restored `interactionState`.
  public private(set) var webView: WKWebView

  /// Container for webView + Inspector. WebKit manages the split inside this.
  private let browserHostView = NSView()

  /// Status-bar-style preview that shows the URL under the cursor
  /// while the user hovers a link. Populated by the JS content script
  /// registered in ``init(frame:)``.
  public let hoverLinkOverlay = HoverLinkOverlayView()

  /// Retained so the `WKUserContentController`'s weak handler
  /// reference has something to point at. Without a strong reference
  /// here the handler would be released the moment ``init`` returns.
  /// Re-assigned by `restore()` because the previous handler is bound
  /// to the discarded web view's user content controller.
  private var hoverLinkMessageHandler: HoverLinkMessageHandler
  /// Same strong-reference rationale as ``hoverLinkMessageHandler``,
  /// but for the Chrome Web Store "Add to e05" button intercept.
  /// `nil` on extension-hosted panes — the overlay only makes sense
  /// for ordinary browsing.
  private var chromeWebStoreInstallHandler: ChromeWebStoreInstallHandler?
  /// Replies to the CWS overlay's startup query so the first
  /// rewrite pass already knows which extensions are installed —
  /// otherwise the page flickers between "Add to E05" and "Remove
  /// from E05" once the `didFinish` push catches up.
  private var chromeWebStoreStateHandler: ChromeWebStoreStateHandler?
  /// Strong-references the handler that mirrors the page's horizontal
  /// overflow scroll position into ``horizontalScrollEdge``. Same
  /// strong-reference rationale as the hover-link / CWS handlers: the
  /// user content controller only holds the handler weakly, so without
  /// a property here it would deallocate right after `init` returns.
  /// `nil` on extension-hosted panes (the overscroll-spill router has
  /// no use for an extension popup's scroll state).
  private var scrollEdgeHandler: ScrollEdgeMessageHandler?

  /// Coarse summary of whether the page can scroll horizontally and
  /// in which direction(s) from its current position. Updated from
  /// the ``scrollEdgeUserScript`` content script on `scroll` /
  /// `resize` / DOMContentLoaded, and read by
  /// ``PaneContainerViewController`` when deciding whether a
  /// horizontal scrollWheel gesture should drive page scrolling or
  /// workspace pane navigation. Always `.none` on extension-hosted
  /// panes and on freshly-loaded pages until the first snapshot
  /// arrives — both safely fall through to workspace-handles-it.
  public enum HorizontalScrollEdge: String {
    case none
    case both
    case left
    case right
  }
  public private(set) var horizontalScrollEdge: HorizontalScrollEdge = .none

  /// Paired horizontal constraints for ``hoverLinkOverlay``. Only
  /// one is active at any time; the JS content script decides which
  /// side the preview should live on based on the cursor position.
  private var hoverLinkOverlayLeadingConstraint: NSLayoutConstraint?
  private var hoverLinkOverlayTrailingConstraint: NSLayoutConstraint?

  /// Called when page title changes.
  public var onTitleChange: ((String) -> Void)?
  /// Called when URL changes. The second argument is how the visit
  /// was reached, so the history store can weight typed navigations.
  public var onURLChange: ((URL?, VisitTransition) -> Void)?
  /// Called when back/forward availability changes.
  public var onNavigationStateChange: ((Bool, Bool) -> Void)?
  /// Called when the page's loading state flips. `true` means a
  /// navigation is in progress; the URL bar flips its reload button
  /// into a stop button for the duration.
  public var onLoadingStateChange: ((Bool) -> Void)?
  /// Called when the browser content gains focus (click or key navigation).
  public var onFocusChanged: (() -> Void)?
  /// Called when a navigation response resolves to a download. The
  /// container wires this to `DownloadsManager.adopt(_:)`; the browser
  /// stays decoupled from the download store.
  public var onDownloadStarted: ((WKDownload) -> Void)?
  /// Called when a link should open in a new pane (new column in the
  /// current workspace). Triggered by `target="_blank"` links,
  /// `window.open()`, plain Cmd-clicks on links, and the
  /// "Open in Pane" context-menu item.
  public var onOpenInNewPane: ((URL) -> Void)?
  /// Called when a link should open in a fresh workspace. Triggered
  /// by Shift-clicks on links and the "Open in Workspace" context-
  /// menu item.
  public var onOpenInNewWorkspace: ((URL) -> Void)?
  /// Called when the user clicks the rebranded install / uninstall
  /// button on a Chrome Web Store listing. The first argument is
  /// the 32-character extension ID parsed out of the listing URL;
  /// the second is `true` when the user clicked the "Remove from
  /// E05" form of the button (i.e. the extension is already
  /// installed and the click is an uninstall intent). The
  /// container is expected to thread the ID into
  /// ``ExtensionController/installFromChromeWebStore(extensionID:)``
  /// or
  /// ``ExtensionController/uninstallChromeWebStoreExtension(extensionID:)``
  /// and surface the result.
  public var onChromeWebStoreAction: ((_ extensionID: String, _ uninstall: Bool) -> Void)?
  /// Called when either ``isMuted`` or ``isPlayingAudio`` changes.
  public var onAudioStateChanged: (() -> Void)?
  /// Called after ``suspend()`` detaches the web view, or ``restore()``
  /// rebuilds it. Lets the sidebar swap its per-row "suspended"
  /// affordance without a full worklane rebuild — the same targeted-
  /// update pattern as ``onAudioStateChanged``.
  public var onSuspendedStateChanged: (() -> Void)?

  private var titleObservation: NSKeyValueObservation?
  private var urlObservation: NSKeyValueObservation?
  private var canGoBackObservation: NSKeyValueObservation?
  private var canGoForwardObservation: NSKeyValueObservation?
  private var isLoadingObservation: NSKeyValueObservation?
  private var adblockerObserverTask: Task<Void, Never>?
  private var adblockerWhitelistObserverTask: Task<Void, Never>?
  /// Token for the ``ExtensionController/didChangeNotification``
  /// observer used to keep `window.__e05InstalledExtensions` on the
  /// Chrome Web Store overlay in sync. `nil` on extension-hosted
  /// panes (the overlay is only attached to ordinary browser panes).
  /// `nonisolated(unsafe)` so `deinit` can release the token under
  /// Swift 6 strict concurrency.
  nonisolated(unsafe) private var extensionsChangedObserver: NSObjectProtocol?

  /// Per-pane mute state. Mutated through ``setMuted(_:)`` /
  /// ``toggleMute()``. The actual audio suppression is performed by
  /// the injected user script (`muteUserScript`) which sets
  /// `.muted = true` on every `<audio>` / `<video>` element and
  /// re-applies on DOM mutations. Web Audio / WebRTC / cross-origin
  /// iframes are out of reach of this approach; if those become a
  /// problem in practice, swap in `_setPageMuted:` SPI.
  public private(set) var isMuted: Bool = false

  /// Whether the page is currently emitting audio (some `<audio>` /
  /// `<video>` element is active, unmuted, with non-zero volume).
  /// The "Playing" speaker glyph is driven by this flag.
  public private(set) var isPlayingAudio: Bool = false

  /// Whether the page has at least one active media element,
  /// regardless of mute state. The mute glyph stays visible on a
  /// muted-but-active tab thanks to this — without it, muting an
  /// audible tab would zero out `isPlayingAudio` and the speaker
  /// affordance would vanish, leaving the user no way to unmute.
  public private(set) var hasActiveMedia: Bool = false

  /// Unique BroadcastChannel name for this pane's mute synchronisation
  /// IIFE. Without a per-pane suffix, every WKWebView on the same
  /// origin would share a single `'e05-mute'` channel and mute flips
  /// in one pane would propagate to every other pane on that origin —
  /// turning the per-pane mute toggle into a global "mute everything
  /// from this site" affordance. The UUID makes each pane's IIFE deaf
  /// to other panes' broadcasts while still reaching its own
  /// same-origin subframes (they get the same script with the same
  /// channel name as the main frame they're nested in).
  /// Re-generated by `restore()` together with the replacement web
  /// view so the new IIFE doesn't share a channel with anything the
  /// old web view may have left in flight.
  private var muteChannelId: String

  /// Workspace-scoped ephemeral data store passed at init, retained so
  /// `restore()` can hand the same store to the replacement
  /// `WKWebView`. Private workspaces share one data store across all
  /// panes in the workspace; suspend/restore must keep that affinity
  /// (cookies, local storage, IndexedDB live with the workspace, not
  /// the individual web view).
  private let savedDataStore: WKWebsiteDataStore?

  /// Snapshot captured by `suspend()`, consumed by `restore()`. While
  /// non-nil the pane shows `placeholderView` instead of a live web
  /// view. The `interactionState` blob (macOS 12+) carries the
  /// back/forward list, scroll position, and form values; `nil` means
  /// the pane never navigated past the initial address, in which case
  /// `restore()` falls back to a plain `load(URLRequest:)`.
  private var suspendedSnapshot: BrowserPaneSnapshot?

  /// Placeholder shown in place of the detached web view while the
  /// pane is suspended. Lazily created on first suspend and reused
  /// across suspend/restore cycles.
  private var placeholderView: BrowserPanePlaceholderView?

  /// URL of the most recent navigation accepted by `decidePolicyFor`.
  /// Captured up-front so `handleNavigationFailure` can keep the
  /// error page anchored to the attempted URL even when WebKit's
  /// `NSError.userInfo` doesn't carry the failing URL key (it's not
  /// populated for every code path) and `webView.url` has already
  /// been cleared after a provisional failure.
  private var lastAttemptedURL: URL?

  /// Provenance of the in-flight navigation, captured at decision time
  /// (`decidePolicyFor` for WebKit-classified types,
  /// `navigate(to:transition:)` for programmatic loads) and consumed
  /// by the `\.url` KVO observer when it records the visit. Reset to
  /// `.link` after each consume so SPA navigations that bypass
  /// `decidePolicyFor` don't inherit a stale `.typed`.
  private var pendingTransition: VisitTransition = .link

  /// Whether this pane was constructed for a `WKWebExtensionContext`
  /// (e.g. an extension's options page). The flag gates services that
  /// only make sense for general web content — adblocker rule-list
  /// late-attach, hover-link preview, persistent site mute — so an
  /// extension-owned pane keeps the configuration WebKit handed it
  /// untouched.
  let isExtensionHosted: Bool

  /// Session-only capability decisions for this pane. A "remember
  /// until I close this pane" choice from the permission prompt
  /// lands here instead of `PermissionsStore` so it evaporates with
  /// the pane. Looked up before the persistent store on every
  /// auto-respond, then read-only afterwards.
  var sessionPermissions: [String: PermissionEntry] = [:]

  /// Pending permission-prompt queue. The frontmost entry maps to
  /// the NSAlert sheet currently displayed; subsequent entries wait
  /// behind it and present when the active sheet completes. The
  /// queue exists so two concurrent WebKit permission requests
  /// (e.g. camera then geolocation arriving in the same tick) do
  /// not stack two near-identical sheets onto the same window. The
  /// detach path (`viewWillMove(toWindow: nil)`) drains every entry
  /// with `.deny` so WebKit's "decisionHandler must fire exactly
  /// once" contract is honoured even when the pane is closed
  /// mid-prompt.
  var pendingPermissionPrompts: [PermissionPromptRequest] = []

  /// Sheet window for the active permission prompt, captured so
  /// the detach path can `endSheet` it explicitly. Weak because
  /// AppKit owns the alert's window and we just want to ride along
  /// for cancellation.
  weak var activePermissionAlertWindow: NSWindow?

  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil {
      drainPermissionPromptsOnDetach()
    }
  }

  public override convenience init(frame: NSRect) {
    self.init(frame: frame, extensionContext: nil, dataStore: nil)
  }

  /// Construct a browser pane. When `extensionContext` is non-nil
  /// **and** the context vends a `webViewConfiguration`, the pane
  /// hosts that extension's resources (options page, etc.) using
  /// the context's own configuration — Apple's documented requirement
  /// for any web view that navigates to a `webkit-extension://` URL.
  /// e05's adblocker / cosmetic filter / hover-link content scripts
  /// are intentionally **not** attached in that case: the
  /// configuration is owned by WebKit's extension machinery and
  /// mutating it could disturb scheme handlers or content worlds the
  /// controller relies on.
  ///
  /// `WKWebExtensionContext.webViewConfiguration` is typed
  /// `Optional` and returns nil when the context isn't yet associated
  /// with a controller. The caller treats that as "fall back to a
  /// regular browser pane"; the resulting `webkit-extension://` load
  /// will surface as a navigation failure rather than crashing.
  ///
  /// `dataStore` swaps the configuration's website data store for a
  /// private-workspace-scoped ephemeral store when non-nil; ignored
  /// when `extensionContext` provides its own configuration so the
  /// extension's storage scope (controller-owned) is preserved.
  public init(
    frame: NSRect,
    extensionContext: WKWebExtensionContext?,
    dataStore: WKWebsiteDataStore?
  ) {
    let built = Self.makeWebView(
      extensionContext: extensionContext, dataStore: dataStore)
    webView = built.webView
    hoverLinkMessageHandler = built.hoverHandler
    chromeWebStoreInstallHandler = built.cwsInstallHandler
    chromeWebStoreStateHandler = built.cwsStateHandler
    scrollEdgeHandler = built.scrollEdgeHandler
    muteChannelId = built.channelId
    isExtensionHosted = built.isExtensionHosted
    savedDataStore = dataStore

    super.init(frame: frame)

    built.hoverHandler.onMessage = { [weak self] url, side in
      guard let self else { return }
      self.applyHoverLinkSide(side)
      if let url, !url.isEmpty {
        self.hoverLinkOverlay.show(url: url)
      } else {
        self.hoverLinkOverlay.hide()
      }
    }
    built.cwsInstallHandler?.onAction = { [weak self] extensionID, uninstall in
      self?.onChromeWebStoreAction?(extensionID, uninstall)
    }
    built.cwsStateHandler?.idsProvider = {
      ExtensionController.shared.installedChromeWebStoreIDs
    }
    built.scrollEdgeHandler?.onChange = { [weak self] edge in
      self?.horizontalScrollEdge = edge
    }
    wantsLayer = true
    layer?.backgroundColor = AppColors.paneSurface.cgColor

    built.webView.onFocusGained = { [weak self] in
      self?.onFocusChanged?()
    }

    setupHostAndWebView()
    setupObservers()
    observeAdBlockerReady()
    observeExtensionInstallChanges()
  }

  /// Subscribe to ``ExtensionController/didChangeNotification`` so
  /// the Chrome Web Store overlay's `window.__e05InstalledExtensions`
  /// mirror tracks the live registry. Skipped on extension-hosted
  /// panes — the overlay isn't installed there.
  private func observeExtensionInstallChanges() {
    guard !isExtensionHosted, extensionsChangedObserver == nil else { return }
    extensionsChangedObserver = NotificationCenter.default.addObserver(
      forName: ExtensionController.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.pushChromeWebStoreInstalledIDs()
      }
    }
  }

  /// Write the current Chrome Web Store install ID list into the
  /// page so the overlay user script can update its branded button
  /// text. No-op on extension-hosted panes and on web views that
  /// aren't currently loaded onto a CWS listing (the snippet still
  /// runs but the rewrite hook bails on the host check).
  private func pushChromeWebStoreInstalledIDs() {
    guard !isExtensionHosted else { return }
    // Skip non-CWS panes — every loaded extension would otherwise
    // trigger an evaluateJavaScript on every browser pane in the
    // process, leaving JS state side-effects on unrelated origins.
    // The user script only attaches its `__e05CWSOverlayRewrite`
    // hook on the CWS hosts, so the snippet is a no-op elsewhere,
    // but skipping the IPC entirely keeps the system audit cleaner.
    guard let host = webView.url?.host(percentEncoded: false),
      host == "chromewebstore.google.com" || host == "chrome.google.com"
    else { return }
    let ids = ExtensionController.shared.installedChromeWebStoreIDs
    let snippet = ChromeWebStoreOverlay.installedIDsSnippet(ids)
    webView.evaluateJavaScript(snippet, completionHandler: nil)
  }

  /// Build a fresh `FocusReportingWebView` with the full per-pane
  /// configuration: web extension controller wiring, adblocker rule
  /// list, cosmetic filter content script, hover-link preview, and
  /// the per-pane mute IIFE. Extracted from `init` so `restore()`
  /// can reuse the exact same wiring when re-creating the web view
  /// after a `suspend()` — `WKWebView` snapshots its configuration
  /// at init time, so a suspend/restore cycle requires building the
  /// whole configuration tree again rather than mutating the old one.
  private static func makeWebView(
    extensionContext: WKWebExtensionContext?,
    dataStore: WKWebsiteDataStore?
  ) -> (
    webView: FocusReportingWebView,
    hoverHandler: HoverLinkMessageHandler,
    cwsInstallHandler: ChromeWebStoreInstallHandler?,
    cwsStateHandler: ChromeWebStoreStateHandler?,
    scrollEdgeHandler: ScrollEdgeMessageHandler?,
    channelId: String,
    isExtensionHosted: Bool
  ) {
    let channelId = "e05-mute-" + UUID().uuidString.lowercased()
    let config: WKWebViewConfiguration
    let hoverHandler = HoverLinkMessageHandler()
    let extensionConfig = extensionContext?.webViewConfiguration
    if let extensionConfig {
      config = extensionConfig
      // Web Inspector is the primary debugging surface for an
      // extension's options page; the context-owned configuration
      // doesn't enable it by default. Setting the preference key
      // doesn't touch the user content controller or scheme
      // handlers, so it stays compatible with the Apple constraint
      // that the extension configuration is otherwise used as-is.
      config.preferences.setValue(true, forKey: "developerExtrasEnabled")
    } else {
      config = WKWebViewConfiguration()
      // Enable Web Inspector — required for _inspector to work.
      config.preferences.setValue(true, forKey: "developerExtrasEnabled")
      // Private workspaces share a workspace-scoped ephemeral data
      // store (cookies, local storage, IndexedDB live in memory and
      // die with the workspace). Default-store panes leave the field
      // alone so WebKit picks up `.default()`.
      if let dataStore {
        config.websiteDataStore = dataStore
      }
      // Attach the shared WKWebExtensionController before the web view is
      // created — WKWebView snapshots its configuration at init time, so
      // setting the controller afterwards is silently ignored.
      config.webExtensionController = ExtensionController.shared.controller
      // Attach the built-in content rule list. Same init-time snapshot
      // constraint applies: the user content controller must already
      // hold its rule lists before WKWebView is initialized.
      AdBlocker.shared.attach(to: config)
      // Install the cosmetic content script and its reply-handler
      // IPC alongside the declarative rule list. The user script +
      // WKScriptMessageHandlerWithReply registrations share the same
      // init-time snapshot constraint as AdBlocker.
      CosmeticFilterEngine.shared.attach(to: config)
      // Hover-link preview: register the content script and fire-and-
      // forget message handler before the web view is constructed so
      // the init-time configuration snapshot picks them up. The handler
      // and the user script must share a content world — otherwise the
      // `webkit.messageHandlers.<name>` lookup in the script returns
      // undefined and every post is silently dropped.
      config.userContentController.addUserScript(Self.hoverLinkUserScript)
      config.userContentController.add(
        hoverHandler,
        contentWorld: Self.hoverLinkContentWorld,
        name: Self.hoverLinkHandlerName
      )
      // Page-mute control: a content script that exposes
      // `window.__e05_setMuted(bool)` and re-applies muting on DOM
      // mutations. No companion message handler — Swift only writes
      // into the JS state, never reads back. The script source is
      // built per-pane so its `BroadcastChannel` name carries the
      // pane's UUID; without that, every WKWebView on the same
      // origin would share one channel and mute toggles in any pane
      // would propagate to every same-origin sibling.
      config.userContentController.addUserScript(
        Self.makeMuteUserScript(channelId: channelId))
    }
    // Chrome Web Store "Add to Chrome" → "Add to e05" overlay. The
    // user script is a no-op on non-CWS pages (the IIFE bails on the
    // host check), so it's cheap to register on every regular browser
    // pane. Skipped on extension-hosted panes — those don't browse
    // CWS and a rogue listener inside an extension's options page
    // would only add surface.
    //
    // The state handler is wired through
    // `addScriptMessageHandlerWithReply` so the user script's
    // startup query resolves synchronously and the first paint
    // already carries the right wording. The fire-and-forget
    // install/uninstall handler stays on the ordinary `add(_:name:)`
    // path.
    let cwsInstallHandler: ChromeWebStoreInstallHandler?
    let cwsStateHandler: ChromeWebStoreStateHandler?
    let scrollEdgeHandler: ScrollEdgeMessageHandler?
    if extensionConfig == nil {
      let installHandler = ChromeWebStoreInstallHandler()
      let stateHandler = ChromeWebStoreStateHandler()
      config.userContentController.addUserScript(ChromeWebStoreOverlay.userScript)
      config.userContentController.add(installHandler, name: ChromeWebStoreOverlay.handlerName)
      config.userContentController.addScriptMessageHandler(
        stateHandler,
        contentWorld: .page,
        name: ChromeWebStoreOverlay.stateHandlerName
      )
      cwsInstallHandler = installHandler
      cwsStateHandler = stateHandler

      // Horizontal-overflow snapshot for the workspace-vs-pane scroll
      // router (`PaneContainerViewController.routeScrollEvent`). The
      // user script lives in the same `.defaultClient` content world
      // as hover-link so the page can't shadow `webkit.messageHandlers`
      // — a content script in `.page` would be visible to ad code that
      // routinely scribbles over `webkit`. Main-frame only: the router
      // cares about the top document's scrollable region; iframe-local
      // horizontal overflow is rare and the iframe owns its own scroll
      // gesture handling anyway.
      let edgeHandler = ScrollEdgeMessageHandler()
      config.userContentController.addUserScript(Self.scrollEdgeUserScript)
      config.userContentController.add(
        edgeHandler,
        contentWorld: Self.scrollEdgeContentWorld,
        name: Self.scrollEdgeHandlerName)
      scrollEdgeHandler = edgeHandler
    } else {
      cwsInstallHandler = nil
      cwsStateHandler = nil
      scrollEdgeHandler = nil
    }
    let webView = FocusReportingWebView(frame: .zero, configuration: config)
    // WKWebView's default UA on macOS 26 omits both `Version/<n>` and
    // `Safari/<rev>`, leaving sites that key off those tokens unable
    // to identify a Safari-equivalent and falling back to "unknown
    // browser" warnings or feature gates. Override with a Safari-
    // suffixed UA so the tokens are present. Extension-hosted panes
    // keep the host controller's UA — extension popup pages don't
    // visit the ecosystem of sites that trigger the warning.
    if extensionConfig == nil {
      webView.customUserAgent = Self.safariUserAgent
      // Pinch-to-magnify mirrors Safari's visual zoom (rendering-layer
      // scale, no reflow). Extension-hosted panes stay at 1.0 because
      // popup UIs are fixed-size and a stray gesture there would feel
      // broken rather than helpful.
      webView.allowsMagnification = true
    }
    return (webView, hoverHandler, cwsInstallHandler, cwsStateHandler, scrollEdgeHandler, channelId, extensionConfig != nil)
  }

  /// Safari-equivalent UA stamped onto every non-extension pane's
  /// `WKWebView.customUserAgent`. WKWebView's default UA on macOS
  /// 26 drops the `Version/<n>` and `Safari/<rev>` tokens, so sites
  /// that gate on them treat the pane as an unknown browser; this
  /// suffix patches both tokens back in while keeping the
  /// `AppleWebKit/605.1.15 (KHTML, like Gecko)` prefix the default
  /// already emits. `Version/` is sourced from the running OS major
  /// so the value follows the macOS-major-equals-Safari-major
  /// convention introduced in macOS 26 without manual bumps. The
  /// `AppleWebKit/` and `Safari/` revisions are hard-coded against
  /// the value the WKWebView default has been emitting for years —
  /// they would only need an update if WebKit itself moves off
  /// `605.1.15`, in which case the failure mode is a slightly
  /// outdated revision (not a missing token), which sites tolerate.
  ///
  /// `Intel Mac OS X 10_15_7` is kept verbatim on Apple Silicon —
  /// Safari itself emits this frozen string for fingerprint surface
  /// minimisation, so matching it is what most server-side parsers
  /// expect when classifying the client as Safari. Don't "fix" it
  /// to report the running CPU architecture.
  ///
  /// Only the `User-Agent` header is patched. WKWebView's default
  /// `Sec-CH-UA*` headers stay as-is, so a site that cross-checks
  /// the UA against UA Client Hints can still detect the mismatch.
  /// No real-world site is known to fail on this today; the day a
  /// site does, a host-keyed override store (see backlog) will be
  /// the better surface to plug Sec-CH-UA spoofing into.
  private static let safariUserAgent: String = {
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
      + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
      + "Version/\(major).0 Safari/605.1.15"
  }()

  /// Subscribe to ``AdBlocker/ruleListDidChangeNotification`` and
  /// ``AdBlockerWhitelistStore/didChangeNotification`` for the
  /// pane's lifetime. Each event triggers a recomputation that
  /// drops the previous rule lists and re-attaches the current set
  /// when the live host is not whitelisted, or leaves the
  /// controller empty when it is. ``WKUserContentController``
  /// accepts post-init `add(_:)` and `removeAllContentRuleLists()`
  /// calls; the configuration is snapshotted at web view init, so
  /// the controller is the right surface for the live mutation.
  ///
  /// Per-host enforcement runs through the user content controller
  /// rather than baking the whitelist into the compiled rule list,
  /// because injecting a per-host bypass into every rule's
  /// `unless-domain` blows up WebKit's NFA-to-DFA conversion on
  /// any non-trivial whitelist + filterlist combination.
  ///
  /// Skipped for extension-hosted panes: the extension context owns
  /// its `WKUserContentController` and post-init mutation could trip
  /// `webkit-extension://` resource resolution.
  private func observeAdBlockerReady() {
    if isExtensionHosted { return }
    adblockerObserverTask = Task { @MainActor [weak self] in
      let stream = NotificationCenter.default.notifications(
        named: AdBlocker.ruleListDidChangeNotification,
        object: nil
      )
      for await _ in stream {
        guard let self else { return }
        self.applyAdblockerRuleListsForCurrentHost()
      }
    }
    adblockerWhitelistObserverTask = Task { @MainActor [weak self] in
      let stream = NotificationCenter.default.notifications(
        named: AdBlockerWhitelistStore.didChangeNotification,
        object: nil
      )
      for await _ in stream {
        guard let self else { return }
        self.applyAdblockerRuleListsForCurrentHost()
      }
    }
  }

  /// Re-evaluate the live URL's host against the whitelist and
  /// install or detach the adblocker rule lists. Called from the
  /// observer streams above and from ``webView(_:didCommit:)`` so
  /// both Settings edits and navigations reach the right state.
  func applyAdblockerRuleListsForCurrentHost() {
    if isExtensionHosted { return }
    let ucc = webView.configuration.userContentController
    ucc.removeAllContentRuleLists()
    if let host = webView.url?.host?.lowercased(),
      AdBlockerWhitelistStore.shared.isWhitelisted(host: host)
    {
      return
    }
    for list in AdBlocker.shared.ruleLists {
      ucc.add(list)
    }
  }

  deinit {
    adblockerObserverTask?.cancel()
    adblockerWhitelistObserverTask?.cancel()
    if let token = extensionsChangedObserver {
      NotificationCenter.default.removeObserver(token)
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  // MARK: - Setup

  private func setupHostAndWebView() {
    // browserHostView uses Auto Layout to fill BrowserPaneView
    browserHostView.translatesAutoresizingMaskIntoConstraints = false
    browserHostView.wantsLayer = true
    addSubview(browserHostView)
    NSLayoutConstraint.activate([
      browserHostView.topAnchor.constraint(equalTo: topAnchor),
      browserHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
      browserHostView.trailingAnchor.constraint(equalTo: trailingAnchor),
      browserHostView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    // Hover-link preview sits above browserHostView at the bottom
    // edge. `hitTest → nil` (in HoverLinkOverlayView) keeps it
    // click-through so the preview never blocks page interaction.
    // Leading is the default side; `applyHoverLinkSide` flips the
    // active constraint to trailing when the cursor drifts under
    // the preview (Safari-style flip).
    hoverLinkOverlay.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hoverLinkOverlay)
    let leading = hoverLinkOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
    let trailing = hoverLinkOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6)
    hoverLinkOverlayLeadingConstraint = leading
    hoverLinkOverlayTrailingConstraint = trailing
    leading.isActive = true
    NSLayoutConstraint.activate([
      hoverLinkOverlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      hoverLinkOverlay.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
    ])

    attachWebView()
  }

  /// Attach `webView` to `browserHostView` with the autoresizing
  /// layout and background-fill suppression. Called from
  /// `setupHostAndWebView()` at init time and from `restore()` after
  /// a fresh `WKWebView` replaces the suspended one.
  private func attachWebView() {
    // webView uses autoresizing mask inside browserHostView (not Auto Layout).
    // This lets WebKit manage webView.frame directly when Inspector is attached.
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = true
    webView.autoresizingMask = [.width, .height]
    webView.frame = browserHostView.bounds
    // Disable the web view's own background fill so the host layer's
    // dark color shows through before the loaded page paints. Without
    // this, WKWebView briefly renders its default opaque white surface
    // on first attach. `drawsBackground` is a long-stable private
    // property accessed via KVC; there is no public replacement.
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = AppColors.paneSurface
    browserHostView.addSubview(webView)
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AppColors.paneSurface.cgColor
      webView.underPageBackgroundColor = AppColors.paneSurface
    }
  }

  public override func layout() {
    super.layout()
    // Only update webView frame when Inspector is NOT attached.
    // When attached, WebKit manages both webView and inspector frames.
    if !isInspectorOpen {
      webView.frame = browserHostView.bounds
    }
  }

  private func setupObservers() {
    titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
      guard let title = change.newValue ?? nil else { return }
      DispatchQueue.main.async { self?.onTitleChange?(title) }
    }
    urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, change in
      guard let url = change.newValue ?? nil else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.onURLChange?(url, self.pendingTransition)
        // Reset so a subsequent SPA `pushState` URL change — which
        // never reaches `decidePolicyFor` — records as an ordinary
        // link instead of inheriting this navigation's type.
        self.pendingTransition = .link
        self.foldSPAURLChangeIntoRestoredHistory(url)
        // Warm the favicon cache so sidebar worklane rows and URL
        // bar suggestions can stop showing the generic `globe`
        // placeholder for this host. Synchronous main-thread call
        // because FaviconCache is `@MainActor`; the actual network
        // fetch runs inside its own Task.
        if let scheme = url.scheme, scheme == "http" || scheme == "https",
          let host = url.host(percentEncoded: false)
        {
          FaviconCache.shared.prefetch(for: host)
        }
      }
    }
    canGoBackObservation = webView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        // `…Effective` properties OR the live `WKBackForwardList`
        // with the restored shadow stack so the URL bar's
        // back/forward affordances stay enabled while either
        // source has a step. The plain `webView.canGoBack` /
        // `canGoForward` here would be wrong for a freshly
        // restored pane (live list is empty until the first
        // native navigation).
        self.onNavigationStateChange?(self.canGoBackEffective, self.canGoForwardEffective)
      }
    }
    canGoForwardObservation = webView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.onNavigationStateChange?(self.canGoBackEffective, self.canGoForwardEffective)
      }
    }
    isLoadingObservation = webView.observe(\.isLoading, options: [.new, .initial]) { [weak self] _, change in
      guard let isLoading = change.newValue else { return }
      DispatchQueue.main.async { self?.onLoadingStateChange?(isLoading) }
    }
  }

  // MARK: - Restored Session History (cross-launch back/forward)

  /// Saved back history loaded from session.json. Oldest at index 0,
  /// nearest-to-current at the end so `popLast()` yields the
  /// step-back target. Empty unless the pane was constructed via
  /// `installRestoredHistory(...)`.
  private var restoredBackHistoryStack: [URL] = []

  /// Saved forward history. Stored with the nearest-to-current
  /// entry at the end (= the on-disk order reversed) so `popLast()`
  /// yields the step-forward target. Empty unless the pane was
  /// constructed via `installRestoredHistory(...)`.
  private var restoredForwardHistoryStack: [URL] = []

  /// Current URL of the restored session history cursor. Tracked so
  /// `goBackEffective` / `goForwardEffective` can push the
  /// outgoing entry onto the opposite stack when navigating.
  private var restoredHistoryCurrentURL: URL?

  /// True while at least one restored history entry is still in
  /// play. Cleared by `abandonRestoredSessionHistory()` once the
  /// user kicks off a navigation outside the saved cursor (link
  /// click, URL bar entry, etc.). Drives `canGoBackEffective` /
  /// `canGoForwardEffective` so the URL bar's back/forward
  /// affordances stay enabled while the cross-launch history is
  /// still usable.
  public private(set) var usesRestoredSessionHistory: Bool = false

  /// Count of in-flight shadow-protected navigations: every
  /// `goBackEffective` / `goForwardEffective` hop, the
  /// `restore()` anchor load, and the live-target's initial
  /// `installRestoredHistory` + `navigate(to:)` pair each bump
  /// this. The abandon trigger decrements it for every `.other`
  /// `decidePolicyFor` it sees and only abandons when the count
  /// is already zero.
  ///
  /// A counter rather than a `Bool` so two back/forward presses
  /// landing before the first `decidePolicyFor` fires don't lose
  /// one of them — under the Bool model the second press would
  /// see "flag already true", do nothing, and the second
  /// `.other` callback would then find the flag freshly reset
  /// and wipe the shadow stack.
  private var inShadowStackNavigationCount: Int = 0

  /// Seed the cross-launch back/forward shadow stack from a
  /// restored `PaneState`. `back` is oldest-first (matches
  /// `WKBackForwardList.backList` order); `forward` is
  /// nearest-first (matches `WKBackForwardList.forwardList` order)
  /// — both consistent with how `captureSession` writes them.
  /// `current` is the URL the WKWebView is being loaded with as the
  /// restore anchor; it lives in `restoredHistoryCurrentURL` so the
  /// back/forward helpers can move it between stacks.
  public func installRestoredHistory(back: [URL], current: URL, forward: [URL]) {
    restoredBackHistoryStack = back
    restoredForwardHistoryStack = Array(forward.reversed())
    restoredHistoryCurrentURL = current
    usesRestoredSessionHistory = !back.isEmpty || !forward.isEmpty
    notifyNavigationStateChange()
  }

  /// Push the current `canGoBackEffective` / `canGoForwardEffective`
  /// to the URL bar. Called from every mutation of the shadow stack
  /// — the `WKBackForwardList` KVO that drives the same callback
  /// only fires for live-list changes and would miss shadow-stack
  /// updates.
  private func notifyNavigationStateChange() {
    let back = canGoBackEffective
    let fwd = canGoForwardEffective
    onNavigationStateChange?(back, fwd)
  }

  /// True when the URL bar's back affordance should be enabled.
  /// While the restored shadow stack is active, only the shadow
  /// stack counts — each shadow pop's `load(URLRequest:)` appends
  /// to the live `WKBackForwardList`, so OR-ing the two would let
  /// native goBack walk the user back through their own shadow-pop
  /// trail and produce a confusing "cbabc" loop. Once the shadow
  /// stack is abandoned the live list takes over.
  public var canGoBackEffective: Bool {
    if usesRestoredSessionHistory {
      return !restoredBackHistoryStack.isEmpty
    }
    return webView.canGoBack
  }

  /// True when the URL bar's forward affordance should be enabled.
  /// Same shadow-only / live-only split as `canGoBackEffective`.
  public var canGoForwardEffective: Bool {
    if usesRestoredSessionHistory {
      return !restoredForwardHistoryStack.isEmpty
    }
    return webView.canGoForward
  }

  /// Navigate back. Prefers the live `WKBackForwardList` when it
  /// has real entries (so bfcache and in-process state work as
  /// normal), and falls back to popping from the restored shadow
  /// stack with a fresh `load(URLRequest:)`. Returns false when
  /// there is nothing to go back to.
  @discardableResult
  public func goBackEffective() -> Bool {
    // While the shadow stack is active, use ONLY the shadow stack
    // — falling through to `webView.goBack()` after the shadow
    // back stack drained would walk back through the load entries
    // each shadow pop had to append to the live
    // `WKBackForwardList`, producing the "cbabc" loop the user
    // observed. Once the shadow stack is abandoned the live list
    // takes over.
    if usesRestoredSessionHistory {
      guard !restoredBackHistoryStack.isEmpty else {
        return false
      }
      let target = restoredBackHistoryStack.popLast()!
      if let outgoing = restoredHistoryCurrentURL {
        restoredForwardHistoryStack.append(outgoing)
      }
      restoredHistoryCurrentURL = target
      inShadowStackNavigationCount += 1
      notifyNavigationStateChange()
      webView.load(URLRequest(url: target))
      return true
    }
    if webView.canGoBack {
      webView.goBack()
      return true
    }
    return false
  }

  /// Mirror of `goBackEffective` for the forward direction.
  @discardableResult
  public func goForwardEffective() -> Bool {
    if usesRestoredSessionHistory {
      guard !restoredForwardHistoryStack.isEmpty else {
        return false
      }
      let target = restoredForwardHistoryStack.popLast()!
      if let outgoing = restoredHistoryCurrentURL {
        restoredBackHistoryStack.append(outgoing)
      }
      restoredHistoryCurrentURL = target
      inShadowStackNavigationCount += 1
      notifyNavigationStateChange()
      webView.load(URLRequest(url: target))
      return true
    }
    if webView.canGoForward {
      webView.goForward()
      return true
    }
    return false
  }

  /// The current shadow back history as URL strings, in the same
  /// "oldest first" order `WKBackForwardList.backList` would yield
  /// (and the same order `PaneState.backHistory` is written in by
  /// `captureSession`). Empty when no shadow stack is installed.
  public var restoredBackHistoryURLs: [String] {
    restoredBackHistoryStack.map { $0.absoluteString }
  }

  /// The current shadow forward history as URL strings, in the
  /// same "nearest first" order `WKBackForwardList.forwardList`
  /// would yield. Internally the stack is stored reversed for
  /// pop-friendliness, so this accessor reverses it back before
  /// emitting.
  public var restoredForwardHistoryURLs: [String] {
    restoredForwardHistoryStack.reversed().map { $0.absoluteString }
  }

  /// Caller declares that the very next `webView.load(URLRequest:)`
  /// is the anchor load matching the shadow stack's current URL —
  /// not a user-initiated navigation. Bumps
  /// `inShadowStackNavigationCount` so the abandon trigger absorbs
  /// the resulting `.other` callback instead of wiping the just-
  /// installed shadow stack. `PaneModel.init`'s live-restore branch
  /// calls this immediately before `navigate(to:)`; the suspended
  /// branch doesn't because no load runs until `restore()`, which
  /// counts its own load already.
  public func expectAnchorLoad() {
    inShadowStackNavigationCount += 1
  }

  /// Record a user-initiated navigation into the shadow stack:
  /// the outgoing `restoredHistoryCurrentURL` becomes the newest
  /// back entry, the forward stack is cleared (the user steered
  /// away from whatever was queued there — that's how browsers'
  /// back/forward semantics work), and `newCurrent` becomes the
  /// cursor. Called from the abandon-trigger replacement when
  /// a `.linkActivated` / `.formSubmitted` / user-driven
  /// `.other` arrives, so the shadow stack tracks the live
  /// content cursor instead of being dropped wholesale.
  private func recordUserNavigation(newCurrent: URL) {
    guard usesRestoredSessionHistory else { return }
    if let outgoing = restoredHistoryCurrentURL, outgoing != newCurrent {
      restoredBackHistoryStack.append(outgoing)
    }
    restoredForwardHistoryStack.removeAll()
    restoredHistoryCurrentURL = newCurrent
    notifyNavigationStateChange()
  }

  /// Drop the restored shadow stack outright (back/forward/current
  /// all cleared). Used by `handleShadowStackAbandonment` for paths
  /// that can't be folded into the stack: native back/forward gesture
  /// swipes (which bypass our URL bar buttons and arrive as
  /// `.backForward`), and the `.other` fallback where the action
  /// carries no usable URL. Regular link/form/URL-bar navigations
  /// take the `recordUserNavigation` path instead — they get folded
  /// into the stack rather than dropping it.
  public func abandonRestoredSessionHistory() {
    guard usesRestoredSessionHistory else { return }
    restoredBackHistoryStack.removeAll()
    restoredForwardHistoryStack.removeAll()
    restoredHistoryCurrentURL = nil
    usesRestoredSessionHistory = false
    notifyNavigationStateChange()
  }

  /// Fold a `webView.url` KVO change into the shadow stack when it
  /// represents an SPA navigation (e.g. astro View Transitions,
  /// Next.js Link routing) that `decidePolicyFor` cannot see because
  /// the page used `history.pushState` / `replaceState` rather than a
  /// real HTTP navigation. The early returns are written so the cost
  /// for a pane without a restored shadow stack is a single Bool
  /// check — that's almost every pane after the first user-initiated
  /// navigation past the saved cursor.
  ///
  /// We rely on `decidePolicyFor` for HTTP-level navigations: those
  /// fire `recordUserNavigation` *before* `webView.url` updates, so by
  /// the time this observer runs `restoredHistoryCurrentURL` already
  /// equals the new URL and the equality check short-circuits the
  /// double-fold. Only SPA pushStates reach the `recordUserNavigation`
  /// call below.
  private func foldSPAURLChangeIntoRestoredHistory(_ newURL: URL) {
    guard usesRestoredSessionHistory else { return }
    guard inShadowStackNavigationCount == 0 else { return }
    guard restoredHistoryCurrentURL != newURL else { return }
    recordUserNavigation(newCurrent: newURL)
  }

  /// Decide whether a main-frame navigation should drop the
  /// restored shadow stack. Called from
  /// `webView(_:decidePolicyFor navigationAction:)`. The shadow
  /// stack only exists to cover the gap between session restore
  /// and the first live navigation; once the user steers away
  /// from the saved cursor — by clicking a link, submitting a
  /// form, typing in the URL bar, or entering native
  /// back/forward via gesture — the live `WKBackForwardList`
  /// takes over and the saved list would only diverge.
  ///
  /// User-initiated navigations (link click, form submit, URL bar
  /// entry, palette navigate, …) get folded into the shadow stack
  /// instead of dropping it: the current URL becomes the newest
  /// back entry, the forward list is cleared, and the new URL
  /// becomes the cursor. This keeps the shadow stack as the sole
  /// source of truth for back/forward across the pane's lifetime
  /// — `WKBackForwardList` would otherwise be polluted by every
  /// `goBackEffective`/`goForwardEffective` `load(URLRequest:)`
  /// and a user-typed navigation past a shadow-popped page would
  /// leave the previously-forward entries visible in the live
  /// list ("a → b → d → c" symptom).
  ///
  /// The exception is the navigation our own
  /// `goBackEffective` / `goForwardEffective` /
  /// `installRestoredHistory` anchor load kicks via
  /// `load(URLRequest:)`. Those arrive as `.other` and we count
  /// them with `inShadowStackNavigationCount` so this method can
  /// distinguish "our shadow-stack hop" from "user-initiated
  /// other-navigation". `.backForward` is a defensive abandon
  /// path for native gesture swipes that bypass our buttons.
  private func handleShadowStackAbandonment(for action: WKNavigationAction) {
    guard usesRestoredSessionHistory else { return }
    switch action.navigationType {
    case .linkActivated, .formSubmitted, .formResubmitted:
      if let url = action.request.url {
        recordUserNavigation(newCurrent: url)
      }
    case .backForward:
      // Native gesture (two-finger swipe) — bypasses our URL bar
      // back/forward buttons, so the shadow stack can't track it.
      // Drop and let the live list take over.
      abandonRestoredSessionHistory()
    case .reload:
      // No-op: reload doesn't move either cursor.
      break
    case .other:
      if inShadowStackNavigationCount > 0 {
        // Our own goBackEffective / goForwardEffective /
        // installRestoredHistory anchor load.
        inShadowStackNavigationCount -= 1
      } else if let url = action.request.url {
        // Plain URL-bar entry, palette navigate, `navigate(to:)`
        // from elsewhere. Fold into the shadow stack instead of
        // abandoning so the forward list reflects this user
        // navigation's "no forward yet" state.
        recordUserNavigation(newCurrent: url)
      } else {
        abandonRestoredSessionHistory()
      }
    @unknown default:
      abandonRestoredSessionHistory()
    }
  }

  // MARK: - Suspend / Restore

  /// State captured by ``suspend()`` and consumed by ``restore()``.
  /// `interactionState` carries the back/forward list, scroll
  /// position, and form values; preserved verbatim because the
  /// underlying `WKInteractionState` blob is opaque to us — WebKit
  /// owns the schema.
  public struct BrowserPaneSnapshot {
    public let url: URL
    public let title: String?
    public let interactionState: Data?
  }

  /// True while the pane has no live `WKWebView` (it was detached
  /// by ``suspend()`` and ``restore()`` has not yet rebuilt it).
  public var isSuspended: Bool { suspendedSnapshot != nil }

  /// View that should receive first-responder status when the host
  /// focuses this pane. Returns the live `WKWebView` for a normal
  /// pane and the placeholder while the pane is suspended. Handing
  /// back a detached `WKWebView` here would make
  /// `makeFirstResponder` refuse the change (it rejects views with
  /// no `window`), leaving the host window's responder stranded on
  /// itself; routing through the placeholder lets the responder
  /// chain stay coherent under a user-driven Suspend Pane action.
  public var firstResponderTarget: NSView {
    if let placeholder = placeholderView, isSuspended {
      return placeholder
    }
    return webView
  }

  /// Whether ``suspend()`` would currently make progress (= would
  /// return `true`). Mirrors the three guards in ``suspend()`` so
  /// sweep loops (idle tick / memory-pressure handler / manual
  /// triggers) can pre-filter the call and treat the subsequent
  /// ``suspend()`` as guaranteed to succeed instead of swallowing a
  /// `Bool` return they have no way to act on.
  public var canSuspend: Bool {
    if isSuspended { return false }
    if isExtensionHosted { return false }
    if webView.url == nil, lastAttemptedURL == nil { return false }
    return true
  }

  /// Detach the `WKWebView`, drop it, and show the placeholder.
  /// Returns `false` (and changes nothing) for:
  /// - panes already in the suspended state — idempotent no-op,
  /// - extension-hosted panes — the configuration is owned by
  ///   `WKWebExtensionContext` and cannot be re-instantiated on a
  ///   later restore (Apple's documented constraint),
  /// - panes that never resolved a URL — nothing meaningful to
  ///   snapshot, the address-only state is already cheap.
  @discardableResult
  public func suspend() -> Bool {
    guard !isSuspended else { return false }
    guard !isExtensionHosted else { return false }
    guard let url = webView.url ?? lastAttemptedURL else { return false }

    // Panes restored from a previous session drive back/forward
    // through the shadow URL stack, not WebKit's own list. Capturing
    // `interactionState` for them would make `restore()` reinstate it
    // via a `.backForward` navigation that `handleShadowStackAbandonment`
    // drops the shadow stack on — losing the saved history. Keep the
    // snapshot URL-only for those panes (so `restore()` takes the same
    // plain-`load` path as `suspendInitially`) and only capture
    // `interactionState` when the live `WKBackForwardList` is the
    // source of truth, where the abandon handler is a no-op.
    let rawInteractionState =
      usesRestoredSessionHistory ? nil : webView.interactionState
    if let raw = rawInteractionState, !(raw is Data) {
      // `WKWebView.interactionState` is typed `Any?` (NS_REFINED_FOR_SWIFT)
      // because WebKit refuses to expose the underlying opaque type, but
      // every shipping macOS has handed back `Data`. If that ever
      // changes, the snapshot silently drops back/forward + scroll +
      // form values, so surface the mismatch rather than discard state.
      logger.warning(
        "[browser/suspend] interactionState type mismatch: \(type(of: raw))")
    }

    let snapshot = BrowserPaneSnapshot(
      url: url,
      title: webView.title,
      interactionState: rawInteractionState as? Data
    )

    webView.stopLoading()
    webView.pauseAllMediaPlayback(completionHandler: nil)
    tearDownWebViewObservations()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()

    suspendedSnapshot = snapshot
    showPlaceholder(title: snapshot.title, url: snapshot.url)
    onSuspendedStateChanged?()
    return true
  }

  /// Rebuild the `WKWebView` from the snapshot captured by
  /// ``suspend()``, re-attach all delegates and observers, and
  /// either restore the prior `interactionState` (back/forward
  /// list + scroll + form values) or fall back to a fresh
  /// `load(URLRequest:)` when no `interactionState` was captured
  /// (e.g. the pane was constructed pre-suspended with only a URL).
  /// No-op when the pane is not currently suspended.
  @discardableResult
  public func restore() -> Bool {
    guard let snapshot = suspendedSnapshot else { return false }

    hidePlaceholder()

    let built = Self.makeWebView(
      extensionContext: nil, dataStore: savedDataStore)
    webView = built.webView
    hoverLinkMessageHandler = built.hoverHandler
    chromeWebStoreInstallHandler = built.cwsInstallHandler
    chromeWebStoreStateHandler = built.cwsStateHandler
    scrollEdgeHandler = built.scrollEdgeHandler
    muteChannelId = built.channelId
    horizontalScrollEdge = .none

    built.hoverHandler.onMessage = { [weak self] url, side in
      guard let self else { return }
      self.applyHoverLinkSide(side)
      if let url, !url.isEmpty {
        self.hoverLinkOverlay.show(url: url)
      } else {
        self.hoverLinkOverlay.hide()
      }
    }
    built.cwsInstallHandler?.onAction = { [weak self] extensionID, uninstall in
      self?.onChromeWebStoreAction?(extensionID, uninstall)
    }
    built.cwsStateHandler?.idsProvider = {
      ExtensionController.shared.installedChromeWebStoreIDs
    }
    built.scrollEdgeHandler?.onChange = { [weak self] edge in
      self?.horizontalScrollEdge = edge
    }
    built.webView.onFocusGained = { [weak self] in
      self?.onFocusChanged?()
    }

    attachWebView()
    setupObservers()
    observeAdBlockerReady()

    // Suppress the shadow-stack abandon trigger for the load
    // `restore()` kicks below: bringing a suspended pane back to
    // life is not "the user navigated away from the saved cursor"
    // — they just focused the pane.
    //
    // `interactionState` is only ever non-nil here for panes whose
    // live `WKBackForwardList` is the source of truth (`suspend()`
    // skips the capture when `usesRestoredSessionHistory` is set).
    // For those panes `handleShadowStackAbandonment` early-returns,
    // so the `.backForward` navigation the reinstated state kicks is
    // harmless and no `.backForward` carve-out is needed. The `else`
    // branch's plain `load(URLRequest:)` — used by shadow-stack panes
    // and pre-suspended (`suspendInitially`) panes — arrives as
    // `.other` and is absorbed by the counter bumped here.
    inShadowStackNavigationCount += 1
    if let data = snapshot.interactionState {
      // Assigning `interactionState` reinstates the back/forward
      // list, scroll position, and form values, and kicks off a
      // load of the current entry — no separate `load()` call.
      webView.interactionState = data
    } else {
      webView.load(URLRequest(url: snapshot.url))
    }

    suspendedSnapshot = nil
    onSuspendedStateChanged?()
    return true
  }

  /// Initialise a placeholder-only pane that has not yet built its
  /// `WKWebView`. Callers use this to defer the first load until the
  /// pane is focused. The pane shows the placeholder immediately;
  /// `restore()` builds the real web view on first focus.
  ///
  /// Unlike ``suspend()`` this path does not fire
  /// ``onSuspendedStateChanged``. The callback exists to flip
  /// pre-built sidebar rows from live to suspended (or back) during
  /// the suspend sweep; at the moment `suspendInitially` runs,
  /// `setupPaneCallbacks` hasn't wired the callback yet and the
  /// sidebar reads the row's initial state synchronously through
  /// `ReloadInput.paneIsSuspended` instead. Inverting that order
  /// would also work; the current sequence keeps the wiring simpler.
  public func suspendInitially(url: URL, title: String?) {
    guard !isSuspended else { return }
    guard !isExtensionHosted else { return }

    let snapshot = BrowserPaneSnapshot(
      url: url, title: title, interactionState: nil)

    webView.stopLoading()
    webView.pauseAllMediaPlayback(completionHandler: nil)
    tearDownWebViewObservations()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
    webView.removeFromSuperview()

    suspendedSnapshot = snapshot
    showPlaceholder(title: title, url: url)
  }

  private func tearDownWebViewObservations() {
    titleObservation?.invalidate()
    titleObservation = nil
    urlObservation?.invalidate()
    urlObservation = nil
    canGoBackObservation?.invalidate()
    canGoBackObservation = nil
    canGoForwardObservation?.invalidate()
    canGoForwardObservation = nil
    isLoadingObservation?.invalidate()
    isLoadingObservation = nil
    adblockerObserverTask?.cancel()
    adblockerObserverTask = nil
    adblockerWhitelistObserverTask?.cancel()
    adblockerWhitelistObserverTask = nil
  }

  private func showPlaceholder(title: String?, url: URL) {
    let view = placeholderView ?? BrowserPanePlaceholderView()
    view.configure(title: title, url: url)
    // Route placeholder clicks through the pane's normal focus
    // callback so the host's `setFocus` path runs and triggers
    // `restoreIfSuspended()`. Without this the suspended pane is
    // unclickable: the `WKWebView` is detached and there's no
    // other responder on the pane to swallow `mouseDown`.
    view.onClick = { [weak self] in
      self?.onFocusChanged?()
    }
    if view.superview == nil {
      view.translatesAutoresizingMaskIntoConstraints = false
      // Below the hover-link overlay so the overlay stays on top
      // regardless of placeholder lifecycle.
      addSubview(view, positioned: .below, relativeTo: hoverLinkOverlay)
      NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: topAnchor),
        view.leadingAnchor.constraint(equalTo: leadingAnchor),
        view.trailingAnchor.constraint(equalTo: trailingAnchor),
        view.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }
    placeholderView = view
  }

  private func hidePlaceholder() {
    placeholderView?.removeFromSuperview()
    placeholderView = nil
  }

  // MARK: - Navigation

  public func navigate(to urlString: String, transition: VisitTransition = .other) {
    var normalized = urlString.trimmingCharacters(in: .whitespaces)
    // about: scheme uses "about:blank" format (no "://")
    if !normalized.contains("://"), !normalized.hasPrefix("about:") {
      normalized = "https://" + normalized
    }
    guard let url = URL(string: normalized),
      let scheme = url.scheme,
      ["https", "http", "about", PaneAddress.extensionScheme].contains(scheme)
    else { return }
    // WebKit reports programmatic loads as `.other`; record the
    // caller's intent (URL bar entry = `.typed`) so the `\.url` KVO
    // observer attributes the visit correctly.
    pendingTransition = transition
    webView.load(URLRequest(url: url))
  }

  /// Render an in-pane error page for a `webkit-extension://` URL
  /// that has no resolvable `WKWebExtensionContext` — extension was
  /// removed, disabled, or the URL refers to a UUID e05 has never
  /// loaded. WebKit's default for this is a silent navigation failure
  /// that paints as a blank pane, which is hostile when the user just
  /// clicked a stale options-page link or pasted a URL. Routes through
  /// the same `loadHTMLErrorPage` machinery as `didFailProvisionalNavigation`
  /// so all error surfaces share one visual language.
  public func loadExtensionUnavailableError(for url: URL) {
    let identifier = url.host ?? "(unknown)"
    let escaped = Self.htmlEscape(identifier)
    loadHTMLErrorPage(
      iconDataURI: Self.puzzleIconDataURI,
      title: "\(identifier) is not available",
      descriptionHTML:
        "<strong>\(escaped)</strong> is not loaded in e05. "
        + "It may have been removed, disabled, or never installed.",
      errorCode: "ERR_EXTENSION_NOT_FOUND",
      attemptedURL: url
    )
  }

  /// Render an in-pane error page for a generic navigation failure
  /// (DNS lookup failed, connection refused, TLS error, etc.). Mirrors
  /// Brave / Chromium's net error pages — short title, host-aware
  /// description with the failing host in bold, and an
  /// `ERR_*` code identifier the user can paste into a search engine.
  private func loadNavigationErrorPage(error: NSError, attemptedURL: URL?) {
    let info = Self.navigationErrorInfo(forCode: error.code, host: attemptedURL?.host)
    loadHTMLErrorPage(
      iconDataURI: Self.triangleIconDataURI,
      title: info.title,
      descriptionHTML: info.descriptionHTML,
      errorCode: info.errorCode,
      attemptedURL: attemptedURL
    )
  }

  /// Shared HTML renderer for both the extension and navigation error
  /// surfaces. `iconDataURI` is the pre-rendered SF Symbol PNG (one
  /// per error family); `descriptionHTML` is the caller's
  /// pre-escaped fragment so a `<strong>` host emphasis can render
  /// without round-tripping through plain-text. `attemptedURL` lets
  /// the URL bar keep the original target visible and lets `reload`
  /// re-attempt the network request — a server-not-yet-running
  /// workflow ("start the dev server, hit ⌘R") would otherwise
  /// require re-typing the URL because the page is loaded as
  /// `about:blank` when no `attemptedURL` is available.
  private func loadHTMLErrorPage(
    iconDataURI: String,
    title: String,
    descriptionHTML: String,
    errorCode: String,
    attemptedURL: URL?
  ) {
    let escapedTitle = Self.htmlEscape(title)
    let escapedCode = Self.htmlEscape(errorCode)
    let iconTag =
      iconDataURI.isEmpty
      ? ""
      : """
        <img class="icon" src="\(iconDataURI)" alt="" aria-hidden="true">
        """
    let html = """
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <title>\(escapedTitle)</title>
      <style>
        :root { color-scheme: dark; }
        html, body { margin: 0; padding: 0; background: #1d1d1d; color: #e8e8e8;
          font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
        body { display: flex; align-items: flex-start; justify-content: center;
          min-height: 100vh; padding: 64px 32px; box-sizing: border-box; }
        main { max-width: 640px; width: 100%; }
        .icon { width: 56px; height: 56px; display: block; margin-bottom: 24px; }
        h1 { font-size: 22px; font-weight: 600; margin: 0 0 16px; line-height: 1.3;
          color: #e8e8e8; }
        p { font-size: 14px; color: #a8a8a8; margin: 0 0 12px; line-height: 1.5; }
        p strong { color: #e8e8e8; font-weight: 600; }
        .code { font-family: ui-monospace, "SF Mono", Menlo, monospace;
          color: #6e6e6e; font-size: 12px; margin-top: 28px; letter-spacing: 0.02em; }
      </style>
      </head>
      <body>
      <main>
        \(iconTag)
        <h1>\(escapedTitle)</h1>
        <p>\(descriptionHTML)</p>
        <p class="code">\(escapedCode)</p>
      </main>
      </body>
      </html>
      """
    loadAlternateHTMLOrFallback(html: html, attemptedURL: attemptedURL)
  }

  /// Try Safari's private `_loadAlternateHTMLString:baseURL:forUnreachableURL:`
  /// SPI so the URL bar keeps the attempted URL and `webView.reload()`
  /// re-attempts the original network request. The SPI is invoked
  /// through the Objective-C runtime (`method(for:)` + `unsafeBitCast`
  /// to a `@convention(c)` function pointer): a Swift `@objc protocol`
  /// cast would have required formal conformance, which `WKWebView`
  /// doesn't declare for our protocol type, so the cast silently
  /// returned nil and the fallback path painted `about:blank`. Falls
  /// back to `loadHTMLString` (which sets `webView.url` to
  /// about:blank, losing the attempted URL) when no URL was tracked
  /// or the selector ever disappears from a future WebKit drop.
  private func loadAlternateHTMLOrFallback(html: String, attemptedURL: URL?) {
    let selector = NSSelectorFromString(
      "_loadAlternateHTMLString:baseURL:forUnreachableURL:"
    )
    if let attemptedURL, webView.responds(to: selector),
      let imp = webView.method(for: selector)
    {
      typealias Fn = @convention(c) (
        AnyObject, Selector, NSString, NSURL?, NSURL
      ) -> Void
      let fn = unsafeBitCast(imp, to: Fn.self)
      fn(webView, selector, html as NSString, nil, attemptedURL as NSURL)
      return
    }
    webView.loadHTMLString(html, baseURL: nil)
  }

  /// HTML-escape `<>&"'` so an attacker-controlled host segment
  /// can't inject markup into the error page. The page is loaded
  /// with `baseURL: nil` so any injected script would be sandboxed
  /// to about:blank, but escaping is still cheap insurance.
  private static func htmlEscape(_ input: String) -> String {
    input
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }

  /// Map a single `NSURLError` code to the title / description HTML /
  /// error code triple used by the generic error page. Mirrors the
  /// most common Chromium net-error surfaces; codes outside the
  /// switch list fall through to a generic `ERR_FAILED` page so the
  /// user sees *something* instead of the WebKit default of a blank
  /// pane plus a bounce back to the previous URL.
  private struct NavigationErrorInfo {
    let title: String
    let descriptionHTML: String
    let errorCode: String
  }

  private static func navigationErrorInfo(
    forCode code: Int, host rawHost: String?
  ) -> NavigationErrorInfo {
    let displayHost: String =
      rawHost.map { "<strong>\(htmlEscape($0))</strong>" } ?? "the page"
    switch code {
    case NSURLErrorCannotFindHost:
      return NavigationErrorInfo(
        title: "This site can't be reached",
        descriptionHTML: "\(displayHost)'s server IP address could not be found.",
        errorCode: "ERR_NAME_NOT_RESOLVED"
      )
    case NSURLErrorCannotConnectToHost:
      return NavigationErrorInfo(
        title: "This site can't be reached",
        descriptionHTML: "\(displayHost) refused to connect.",
        errorCode: "ERR_CONNECTION_REFUSED"
      )
    case NSURLErrorTimedOut:
      return NavigationErrorInfo(
        title: "This site can't be reached",
        descriptionHTML: "\(displayHost) took too long to respond.",
        errorCode: "ERR_CONNECTION_TIMED_OUT"
      )
    case NSURLErrorDNSLookupFailed:
      return NavigationErrorInfo(
        title: "This site can't be reached",
        descriptionHTML: "DNS lookup for \(displayHost) failed.",
        errorCode: "ERR_NAME_NOT_RESOLVED"
      )
    case NSURLErrorNotConnectedToInternet:
      return NavigationErrorInfo(
        title: "No internet",
        descriptionHTML: "Check your network connection and try again.",
        errorCode: "ERR_INTERNET_DISCONNECTED"
      )
    case NSURLErrorNetworkConnectionLost:
      return NavigationErrorInfo(
        title: "Network changed",
        descriptionHTML: "The network connection was lost while loading \(displayHost).",
        errorCode: "ERR_NETWORK_CHANGED"
      )
    case NSURLErrorSecureConnectionFailed,
      NSURLErrorServerCertificateUntrusted,
      NSURLErrorServerCertificateHasBadDate,
      NSURLErrorServerCertificateHasUnknownRoot,
      NSURLErrorServerCertificateNotYetValid,
      NSURLErrorClientCertificateRejected,
      NSURLErrorClientCertificateRequired:
      return NavigationErrorInfo(
        title: "Your connection is not private",
        descriptionHTML: "\(displayHost)'s certificate could not be verified.",
        errorCode: "ERR_CERT_AUTHORITY_INVALID"
      )
    case NSURLErrorUnsupportedURL, NSURLErrorBadURL:
      return NavigationErrorInfo(
        title: "This page can't be displayed",
        descriptionHTML: "The URL is invalid or uses an unsupported scheme.",
        errorCode: "ERR_UNSUPPORTED_URL"
      )
    default:
      return NavigationErrorInfo(
        title: "This page can't be displayed",
        descriptionHTML: "Something went wrong loading \(displayHost).",
        errorCode: "ERR_FAILED"
      )
    }
  }

  /// SF Symbol rendered to a PNG once at module init and embedded as
  /// a data URI in the error page. The palette configuration tints
  /// the symbol explicitly to a light gray so it stays visible
  /// against the dark page background — a plain template image
  /// PNG-encodes as black and renders invisible. Returns an empty
  /// string when SF Symbol resolution fails on the host; the caller
  /// drops the `<img>` tag and the page degrades to text-only.
  private static func makeErrorIconDataURI(symbolName: String) -> String {
    let pointSize: CGFloat = 56
    let palette = NSImage.SymbolConfiguration(
      paletteColors: [NSColor(white: 0.66, alpha: 1.0)]
    )
    let base = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    guard
      let symbol = NSImage(
        systemSymbolName: symbolName, accessibilityDescription: nil
      )?.withSymbolConfiguration(base.applying(palette)),
      let tiff = symbol.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return "" }
    return "data:image/png;base64,\(png.base64EncodedString())"
  }

  /// Generic navigation-failure icon (`exclamationmark.triangle`).
  private static let triangleIconDataURI: String = makeErrorIconDataURI(
    symbolName: "exclamationmark.triangle"
  )

  /// Extension-not-available icon (`puzzlepiece.extension`).
  private static let puzzleIconDataURI: String = makeErrorIconDataURI(
    symbolName: "puzzlepiece.extension"
  )

  // MARK: - Web Inspector

  /// Private API selectors on _WKInspector.
  private enum InspectorSelector {
    static let attach = NSSelectorFromString("attach")
    static let show = NSSelectorFromString("show")
    static let close = NSSelectorFromString("close")
  }
  private static let inspectorKey = "_inspector"

  /// Whether the Web Inspector is currently open.
  public private(set) var isInspectorOpen = false

  /// Toggle Web Inspector. Opens inline inside this view (Safari/Chrome-style split).
  public func toggleInspector() {
    guard let inspector = webView.value(forKey: Self.inspectorKey) as? NSObject else {
      logger.error("_inspector not available")
      return
    }
    // Update state BEFORE side effects so layout() sees the correct value during reentrant calls
    if isInspectorOpen {
      isInspectorOpen = false
      inspector.perform(InspectorSelector.close)
      webView.frame = browserHostView.bounds
      logger.debug("Inspector closed")
    } else {
      isInspectorOpen = true
      // attach BEFORE show so Inspector opens inline from the start
      // (avoids the flash of a separate window when remembered state is detached)
      inspector.perform(InspectorSelector.attach)
      inspector.perform(InspectorSelector.show)
      logger.debug("Inspector opened (inline)")
    }
  }

  // MARK: - Focus

  public override var acceptsFirstResponder: Bool { true }

  // MARK: - Download Interception

  /// Intercept link clicks before WebKit navigates. Modifier-flag
  /// routing replicates the typical browser behaviour:
  ///
  /// - Shift-click → cancel and forward the URL to the new-workspace
  ///   path. The host is responsible for creating the workspace and
  ///   adding the column.
  /// - Cmd-click → cancel and forward to the new-pane path. Since
  ///   Cmd-clicks on plain links also trigger
  ///   `webView(_:createWebViewWith:for:windowFeatures:)` below, the
  ///   guard here is the canonical interception (returning `nil`
  ///   from `createWebView` is a fallback for `target="_blank"` /
  ///   `window.open()` only).
  /// - Anything else → allow the navigation, fall through to the
  ///   download / response-policy delegate below if needed.
  ///
  /// `modifierFlags` is empty for non-user-initiated actions
  /// (programmatic redirects, JS-driven navigations), so this
  /// branching only fires on real link activations.
  public func webView(
    _: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    // Track every accepted main-frame navigation so the error page
    // keeps the attempted URL even when `NSError.userInfo` arrives
    // without `NSURLErrorFailingURLErrorKey` (Apple doesn't promise
    // the key on every failure path).
    if navigationAction.targetFrame?.isMainFrame ?? true,
      let candidate = navigationAction.request.url
    {
      lastAttemptedURL = candidate
    }
    // Capture provenance for the visit the `\.url` KVO observer will
    // record. `.other` covers programmatic loads (including the URL
    // bar's `navigate(to:transition:)`), so leave whatever `navigate`
    // set intact in that case and only overwrite for the types WebKit
    // can classify. Main-frame only — a subframe navigation must not
    // clobber the pending type before the main-frame URL settles.
    if navigationAction.targetFrame?.isMainFrame ?? true {
      switch navigationAction.navigationType {
      case .linkActivated: pendingTransition = .link
      case .formSubmitted, .formResubmitted: pendingTransition = .formSubmitted
      case .backForward: pendingTransition = .backForward
      case .reload: pendingTransition = .reload
      case .other: break
      @unknown default: break
      }
    }
    // Drop / fold the cross-launch shadow stack when a navigation
    // happens that wasn't kicked by `goBackEffective` /
    // `goForwardEffective`. The live `WKBackForwardList` is now
    // the source of truth and the saved URL list would only get
    // out of sync. Deferred until *after* modifier-flag handling
    // below so Shift/Cmd-clicks — which we cancel and forward to
    // a different pane/workspace — don't mutate this pane's
    // shadow stack with a URL that never actually loads here.
    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
    guard navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url
    else {
      if isMainFrame {
        handleShadowStackAbandonment(for: navigationAction)
      }
      decisionHandler(.allow)
      return
    }
    let flags = navigationAction.modifierFlags
    if flags.contains(.shift) {
      decisionHandler(.cancel)
      onOpenInNewWorkspace?(url)
      return
    }
    if flags.contains(.command) {
      decisionHandler(.cancel)
      onOpenInNewPane?(url)
      return
    }
    if isMainFrame {
      handleShadowStackAbandonment(for: navigationAction)
    }
    decisionHandler(.allow)
  }

  /// Decide whether a response should become a download. Explicit
  /// `Content-Disposition: attachment` is the only signal; WKWebView
  /// already renders PDFs / images / media inline by default.
  public func webView(
    _: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
  ) {
    if Self.shouldDownload(navigationResponse.response) {
      decisionHandler(.download)
    } else {
      decisionHandler(.allow)
    }
  }

  // MARK: - WKUIDelegate

  /// Handle `target="_blank"` / `window.open()` / Cmd-click on links
  /// where WebKit asks for a new web view. Always return `nil` —
  /// e05 doesn't host secondary `WKWebView` instances inside the
  /// same pane. Instead, forward the URL to the new-pane path so
  /// the host creates a fresh browser column for it. Returning
  /// `nil` here cancels the popup; the original `decidePolicyFor`
  /// path has already cancelled the parent navigation when
  /// applicable, so there's no double-load risk.
  public func webView(
    _: WKWebView,
    createWebViewWith _: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures _: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url {
      // Shift-click on a `target="_blank"` link still opens in a new
      // workspace; the modifierFlags survive the WebKit hop.
      if navigationAction.modifierFlags.contains(.shift) {
        onOpenInNewWorkspace?(url)
      } else {
        onOpenInNewPane?(url)
      }
    }
    return nil
  }

  /// Camera / microphone permission requests originate here. WebKit
  /// surfaces a single decision per request, so a combined
  /// `.cameraAndMicrophone` request requires a unanimous grant
  /// across both kinds before granting; any deny or undecided slot
  /// resolves to deny so the safer answer wins. An undecided
  /// request falls through to the Safari-style prompt sheet so the
  /// user can record the choice (session-only or persistent) for
  /// every kind in the request at once.
  public func webView(
    _: WKWebView,
    requestMediaCapturePermissionFor origin: WKSecurityOrigin,
    initiatedByFrame _: WKFrameInfo,
    type: WKMediaCaptureType,
    decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    let kinds: [PermissionKind]
    switch type {
    case .camera: kinds = [.camera]
    case .microphone: kinds = [.microphone]
    case .cameraAndMicrophone: kinds = [.camera, .microphone]
    @unknown default:
      logger.warning(
        "[permissions/media] Unknown WKMediaCaptureType raw=\(type.rawValue, privacy: .public); denying"
      )
      kinds = []
    }
    if let resolved = resolvePermissionDecision(host: origin.host, kinds: kinds) {
      decisionHandler(resolved)
      return
    }
    promptForPermission(host: origin.host, kinds: kinds, completion: decisionHandler)
  }

  /// Geolocation permission requests reach the delegate through the
  /// `WKUIDelegatePrivate` SPI instead of a public selector — the
  /// `webView(_:requestGeolocationPermissionFor:initiatedByFrame:decisionHandler:)`
  /// counterpart is gated `WK_MAC_TBA` in WebKit trunk and absent
  /// from every shipping macOS SDK, so `@optional` Swift methods
  /// declared with that name are silently never invoked. The SPI
  /// has been stable since macOS 12 and is what `UIDelegate.mm`
  /// actually dispatches against; the `@objc` selector override
  /// matches it without needing a bridging header. The completion
  /// handler takes `Bool` (legacy shape), so the prompt's
  /// `WKPermissionDecision` is folded down via `== .grant`.
  @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
  public func _webView(
    _: WKWebView,
    requestGeolocationPermissionForOrigin origin: WKSecurityOrigin,
    initiatedByFrame _: WKFrameInfo,
    decisionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    let host = origin.host
    if let resolved = resolvePermissionDecision(host: host, kinds: [.geolocation]) {
      decisionHandler(resolved == .grant)
      return
    }
    promptForPermission(host: host, kinds: [.geolocation]) { decision in
      decisionHandler(decision == .grant)
    }
  }

  /// Web Notification permission requests reach the delegate
  /// through `WKUIDelegatePrivate` SPI (no public counterpart
  /// exists at all on the macOS 26 SDK — `WKUIDelegate.h` has zero
  /// notification selectors). The SPI ships in `WKUIDelegatePrivate.h`
  /// since macOS 10.13.4 and is what `UIDelegate.mm:249, 845-853`
  /// dispatches `Notification.requestPermission()` against.
  ///
  /// An earlier revision attempted to opt in via
  /// `config.preferences.setValue(true, forKey: "_notificationsEnabled")`
  /// based on the `WKPreferencesPrivate.h` reference describing
  /// non-Safari hosts as gated off, but that KVC write wedged
  /// WebKit's init path: the app launched, logged
  /// `installInitialWorkspaceVC done`, and never reached the first
  /// paint. Removing the call leaves the prompt working — macOS 26
  /// ships with the Notification API enabled for arbitrary hosts,
  /// so the opt-in is both unnecessary and actively harmful.
  ///
  /// Display of the resulting notifications is a separate path
  /// (`_WKWebsiteDataStoreDelegate showNotification:`) that bridges
  /// to `UNUserNotificationCenter`, but `UNUserNotificationCenter`
  /// asserts on a non-`.app` bundle, so that lands with the bundle
  /// follow-up. Until then this hook records grants/denies that
  /// will start producing visible notifications once the bundle
  /// work and display delegate ship.
  @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
  public func _webView(
    _: WKWebView,
    requestNotificationPermissionForSecurityOrigin origin: WKSecurityOrigin,
    decisionHandler: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    let host = origin.host
    if let resolved = resolvePermissionDecision(host: host, kinds: [.notification]) {
      decisionHandler(resolved == .grant)
      return
    }
    promptForPermission(host: host, kinds: [.notification]) { decision in
      decisionHandler(decision == .grant)
    }
  }

  /// Look up `(host, kinds)` against the per-pane session dict
  /// first, then `PermissionsStore`. Returns `nil` when any kind is
  /// still undecided so callers can hand the request off to the
  /// prompt UI; any deny in the chain short-circuits to `.deny` so
  /// a partial grant (e.g. mic granted, camera denied) never
  /// escalates into a combined grant.
  ///
  /// Combined-request quirk: a session-only deny for one kind
  /// silently shadows a stored grant for another kind in a combined
  /// request. E.g. the user persists camera as Always-Allow and
  /// then session-denies microphone; a subsequent
  /// `.cameraAndMicrophone` request resolves to `.deny` here
  /// without re-prompting because every slot is decided. This
  /// matches the Brave / Safari "any deny wins" rule, but the deny
  /// side never surfaces a fresh prompt to the user.
  private func resolvePermissionDecision(
    host: String,
    kinds: [PermissionKind]
  ) -> WKPermissionDecision? {
    let normalized = host.lowercased()
    guard !normalized.isEmpty, !kinds.isEmpty else {
      logger.warning(
        "[permissions/resolve] Invalid request (host=\"\(host, privacy: .public)\" kinds=\(kinds.count)); denying"
      )
      return .deny
    }
    var states: [PermissionState] = []
    for kind in kinds {
      if let session = sessionPermissions[normalized]?.state(for: kind) {
        states.append(session)
        continue
      }
      if let stored = PermissionsStore.shared.state(for: normalized, kind: kind) {
        states.append(stored)
        continue
      }
      return nil
    }
    return states.allSatisfy({ $0 == .grant }) ? .grant : .deny
  }

  public func webView(
    _: WKWebView,
    navigationResponse _: WKNavigationResponse,
    didBecome download: WKDownload
  ) {
    onDownloadStarted?(download)
  }

  public func webView(_ webView: WKWebView, didCommit _: WKNavigation!) {
    // A navigation just committed — bleed one shadow-protected
    // navigation off the counter. Zeroing it outright would also
    // erase the protection of any *in-flight* hop whose
    // `decidePolicyFor` has not arrived yet (e.g. a user pressing
    // back twice in quick succession during the anchor load of a
    // suspended-pane restore); the second hop's `.other` callback
    // would then be misread as a user-initiated navigation and
    // fold into the stack instead of being absorbed. Consuming a
    // single slot still drains a leaked counter from a cancelled
    // `decidePolicyFor` — it just takes one commit per leak
    // instead of one commit for the whole queue.
    inShadowStackNavigationCount = max(0, inShadowStackNavigationCount - 1)
    // The committed URL determines whether the adblocker rule
    // lists belong on this pane. A subsequent commit (link click,
    // history navigation) re-evaluates the host so a whitelisted
    // entry only suppresses blocking while the user is actually on
    // that host.
    applyAdblockerRuleListsForCurrentHost()
  }

  public func webView(_: WKWebView, didFinish _: WKNavigation!) {
    // Scan the rendered DOM for a `<link rel="icon">` (or apple-touch
    // variant) and feed the highest-resolution hit to the favicon
    // cache. This covers sites whose `/favicon.ico` route 404s (they
    // declare the icon via <link> instead) and SPAs whose link tags
    // are injected after the initial HTML ships.
    scanPageFavicon()
    // Push the live installed-extension list into the page so the
    // Chrome Web Store overlay can flip its rebranded button text
    // between "Add to E05" and "Remove from E05". WKWebView has no
    // chrome.management equivalent, so this is the only channel by
    // which CWS pages learn that we already have an extension.
    pushChromeWebStoreInstalledIDs()
    // Re-sync mute state into the freshly loaded page. The user
    // script's IIFE runs at document-start with `muted = false`, so
    // a navigation while the pane is muted would leak audio on the
    // new page until the user toggled again.
    if isMuted, !isExtensionHosted {
      webView.evaluateJavaScript(
        Self.muteApplyTrueJS, in: nil, in: Self.muteContentWorld
      ) { result in
        if case .failure(let error) = result {
          logger.warning(
            "[mute/reapply] evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    applySiteMutePreference()
  }

  /// Apply the persistent per-site mute preference to a freshly
  /// landed page. Looks up the current host in `MutedSitesStore` and
  /// flips the pane to `setMuted(true)` when it matches; the
  /// in-tab toggle path stays authoritative once the page has
  /// loaded, so an already-muted pane stays muted regardless of the
  /// store state and the unmute direction is the user's call.
  ///
  /// Re-evaluating on `pushState` / `replaceState` isn't necessary —
  /// the History API's same-origin restriction means the host can't
  /// change without triggering a full navigation, and the store is
  /// keyed by host alone.
  private func applySiteMutePreference() {
    guard !isExtensionHosted, !isMuted,
      let host = webView.url?.host(percentEncoded: false),
      !host.isEmpty,
      MutedSitesStore.shared.isMuted(host: host)
    else { return }
    setMuted(true)
  }

  public func webView(
    _: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: any Error
  ) {
    handleNavigationFailure(error: error)
  }

  public func webView(
    _: WKWebView, didFail _: WKNavigation!, withError error: any Error
  ) {
    handleNavigationFailure(error: error)
  }

  /// Filter benign cancellations (the user clicked another link,
  /// WebKit handed off to a download, an extension URL load aborted
  /// because the context resolved to nil) and route real failures
  /// through `loadNavigationErrorPage` so the pane shows an error
  /// page instead of bouncing back to the previous URL or painting
  /// blank. The `webView.url` fallback covers errors that don't carry
  /// `NSURLErrorFailingURLErrorKey` — `webView.url` is still the
  /// last-attempted URL during a provisional failure.
  private func handleNavigationFailure(error: any Error) {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
      return
    }
    // WebKit's "frame load interrupted" (102 / WebKitErrorDomain) fires
    // when navigation is taken over by another path — typically the
    // download decision flow. Not a real error to surface.
    if nsError.domain == "WebKitErrorDomain", nsError.code == 102 {
      return
    }
    // Resolution order: NSError userInfo (most precise when set) →
    // tracker captured in `decidePolicyFor` (covers errors that don't
    // populate userInfo) → live `webView.url` (cleared on some
    // provisional failures, so it's the weakest signal).
    let attemptedURL: URL? =
      (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
      ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
        .flatMap(URL.init(string:))
      ?? lastAttemptedURL
      ?? webView.url
    // Reload after an unresolvable `webkit-extension://` URL stays on
    // the extension-specific page (puzzle icon, "is not available"
    // copy) instead of falling through to the generic
    // ERR_UNSUPPORTED_URL surface — the extension framing is the
    // user-actionable signal here.
    if let attemptedURL, attemptedURL.scheme == PaneAddress.extensionScheme {
      loadExtensionUnavailableError(for: attemptedURL)
    } else {
      loadNavigationErrorPage(error: nsError, attemptedURL: attemptedURL)
    }
    // Force a `loading == false` notification so the URL bar's ⌘L
    // peek collapses around the error page exactly like it would
    // around a successfully loaded one. The SPI-driven alternate
    // HTML load does not consistently fire the natural KVO
    // `isLoading: true → false` transition (WebKit treats the
    // alternate as a transient continuation of the failed
    // navigation, not a fresh top-level load), so the peek-release
    // path that hangs off `onLoadingStateChange(false)` would
    // otherwise never run.
    onLoadingStateChange?(false)
  }

  private func scanPageFavicon() {
    // Skip chrome-less navigations (about:blank, data:, custom
    // schemes) so we don't evaluate the script on pages that can't
    // carry a meaningful `<link rel="icon">`.
    guard let url = webView.url,
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host(percentEncoded: false), !host.isEmpty
    else { return }
    webView.evaluateJavaScript(
      Self.faviconScanScript,
      in: nil,
      in: .defaultClient
    ) { result in
      guard case .success(let value) = result,
        let href = value as? String,
        !href.isEmpty,
        let url = URL(string: href)
      else { return }
      FaviconCache.shared.ingest(host: host, from: url)
    }
  }

  /// Pick the active `<link rel="icon">` href on the page. Matches
  /// `icon`, `shortcut icon`, and `apple-touch-icon`. Prefers the
  /// first `icon` (or `shortcut icon`) link without a `sizes`
  /// attribute — that's the canonical "default" icon under the HTML
  /// spec, and pages that rotate their favicon over time tend to
  /// keep updating the unsized default while leaving any larger
  /// sized variants stale. `apple-touch-icon` is held out of the
  /// default pool: it's typically a high-res home-screen artwork
  /// (often unsized but implicitly 180×180) and would otherwise
  /// hijack the tab favicon on pages whose touch icon appears
  /// before their regular icon in document order. Falls back to
  /// the largest sized link (including apple-touch-icon) when no
  /// canonical default is present.
  private static let faviconScanScript: String = """
    (function() {
      const links = document.querySelectorAll(
        'link[rel~="icon"], link[rel~="shortcut"], link[rel~="apple-touch-icon"]'
      );
      let defaultHref = null;
      let bestSizedHref = null, bestSizedArea = 0;
      for (const l of links) {
        const href = l.href;
        if (!href) continue;
        const rel = (l.getAttribute('rel') || '').toLowerCase().split(/\\s+/);
        const isCanonical = rel.includes('icon') || rel.includes('shortcut');
        const sizes = (l.getAttribute('sizes') || '').toLowerCase();
        const m = sizes.match(/(\\d+)x(\\d+)/);
        if (m) {
          const area = parseInt(m[1], 10) * parseInt(m[2], 10);
          if (!bestSizedHref || area > bestSizedArea) {
            bestSizedHref = href;
            bestSizedArea = area;
          }
        } else if (isCanonical && !defaultHref) {
          defaultHref = href;
        } else if (!bestSizedHref) {
          bestSizedHref = href;
        }
      }
      return defaultHref || bestSizedHref || '';
    })();
    """

  private static func shouldDownload(_ response: URLResponse) -> Bool {
    guard let http = response as? HTTPURLResponse,
      let disposition = http.value(forHTTPHeaderField: "Content-Disposition")
    else {
      return false
    }
    // Only match the disposition-type token (before the first ";"),
    // per RFC 6266. A plain contains("attachment") would false-
    // positive on inline responses whose filename happens to
    // contain the word, e.g. `inline; filename="attachment.pdf"`.
    let type =
      disposition.split(separator: ";", maxSplits: 1)
      .first
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
      ?? ""
    return type == "attachment"
  }

  // MARK: - Hover-Link Preview

  /// Switch the hover-link overlay between the leading and trailing
  /// edges. Called when the JS content script reports that the
  /// cursor has entered (or left) the overlay's bottom-leading
  /// footprint, so the preview never hides the link the user is
  /// actually pointing at.
  private func applyHoverLinkSide(_ side: String?) {
    let trailing = side == "right"
    guard hoverLinkOverlayTrailingConstraint?.isActive != trailing else { return }
    if trailing {
      hoverLinkOverlayLeadingConstraint?.isActive = false
      hoverLinkOverlayTrailingConstraint?.isActive = true
    } else {
      hoverLinkOverlayTrailingConstraint?.isActive = false
      hoverLinkOverlayLeadingConstraint?.isActive = true
    }
  }

  // MARK: - Mute control

  /// Toggle the pane's mute flag. Wraps ``setMuted(_:)`` so callers
  /// stay state-agnostic.
  public func toggleMute() {
    setMuted(!isMuted)
  }

  /// Set the pane's mute flag and push it to the JS-side controller.
  /// No-op (for the JS push) on extension-hosted panes since they
  /// don't carry the content script — but the Swift-side flag still
  /// flips so the URL bar / sidebar mirror stays in sync.
  public func setMuted(_ muted: Bool) {
    let changed = (muted != isMuted)
    isMuted = muted
    if !isExtensionHosted {
      let js = muted ? Self.muteApplyTrueJS : Self.muteApplyFalseJS
      webView.evaluateJavaScript(js, in: nil, in: Self.muteContentWorld) { result in
        if case .failure(let error) = result {
          logger.warning(
            "[mute/apply] evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    if changed { onAudioStateChanged?() }
  }

  /// Pre-built JS literals for the two boolean flips. Avoids string
  /// interpolation each call and matches the literal `true` form
  /// used by the post-navigation re-application path.
  private static let muteApplyTrueJS =
    "window.__e05_setMuted && window.__e05_setMuted(true)"
  private static let muteApplyFalseJS =
    "window.__e05_setMuted && window.__e05_setMuted(false)"

  /// Probe `WKMediaPlaybackState` + the JS audible verifier once and
  /// publish the result through ``onAudioStateChanged`` if it
  /// differs from the cached value. Driven by the container's
  /// shared 1 Hz tick rather than a per-pane Task — that one task
  /// fans out across every browser pane to keep main-actor wakeups
  /// proportional to "1 per workspace" instead of "1 per pane".
  ///
  /// Skips for extension-hosted panes (no content script, no probe
  /// to run). Idempotent: callers can poll any cadence they like
  /// without state corruption.
  ///
  /// Why the JS probe at all:
  /// `WKMediaPlaybackState.playing` and `.paused` both fire for any
  /// live media element, regardless of whether sound is actually
  /// coming out. `<video autoplay muted>` hero videos register as
  /// `.playing`; niconico's player stays at `.paused` through
  /// visible playback. The injected `__e05_isAudible` walks the DOM
  /// and only returns true for elements that meet
  /// `!paused && !muted && volume>0 && readyState>=2 && !ended`,
  /// which is what users actually mean by "this tab is making
  /// noise". Web Audio / WebRTC / cross-origin iframes are still
  /// out of reach — escalation path is `_setPageMuted:` SPI.
  public func updateAudioStateOnce() async {
    if isExtensionHosted { return }
    let state = await webView.requestMediaPlaybackState()
    var hasActive = false
    var audible = false
    if state != .none {
      let webViewRef = webView
      let world = Self.muteContentWorld
      // The async `evaluateJavaScript` overload bridges return
      // values to Swift `Void` when run in an isolated content
      // world (a long-standing WebKit bug). The closure-based form
      // delivers `id _Nullable` straight through, and pulling the
      // numeric out inside the callback keeps the cross-actor hop
      // Sendable for Swift 6 strict concurrency.
      let bits: Int? = await withCheckedContinuation { cont in
        webViewRef.evaluateJavaScript(
          "(window.__e05_audioState && window.__e05_audioState()) || 0",
          in: nil, in: world
        ) { (r: Result<Any, any Error>) in
          switch r {
          case .success(let raw):
            cont.resume(returning: (raw as? NSNumber)?.intValue)
          case .failure(let error):
            logger.warning(
              "[mute/probe] evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)"
            )
            cont.resume(returning: nil)
          }
        }
      }
      if let b = bits {
        hasActive = (b & 1) != 0
        audible = (b & 2) != 0
      }
    }
    if hasActive != hasActiveMedia || audible != isPlayingAudio {
      hasActiveMedia = hasActive
      isPlayingAudio = audible
      onAudioStateChanged?()
    }
  }

  /// Content world used by the mute user script and Swift-side
  /// `evaluateJavaScript` so the install guard
  /// (`window.__e05MuteInstalled`) and the bridge function
  /// (`window.__e05_setMuted`) are isolated from page scripts.
  private static let muteContentWorld: WKContentWorld = .defaultClient

  /// Build the per-pane mute control content script. Mutes every
  /// `<audio>` / `<video>` element and re-applies on DOM additions
  /// and `muted`-attribute write-backs. Exposes
  /// `window.__e05_setMuted` to Swift so the pane can flip the flag
  /// at any time. Runs in every frame (including same-origin
  /// subframes) — Swift's `evaluateJavaScript` only reaches the main
  /// frame, so each frame's IIFE listens on a `BroadcastChannel` to
  /// pick up flips fired in the main frame. Cross-origin subframes
  /// stay out of reach (same-origin BroadcastChannel only).
  ///
  /// The `channelId` parameter scopes the BroadcastChannel name to
  /// this single pane. A shared name would let mute flips in one
  /// WKWebView reach every other same-origin WKWebView in the host
  /// app, collapsing the per-pane toggle into a global per-site one.
  private static func makeMuteUserScript(channelId: String) -> WKUserScript {
    let source = """
      (function() {
        if (window.__e05MuteInstalled) return;
        window.__e05MuteInstalled = true;

        let muted = false;

        // No-op when the element is already in sync. Page script's own
        // `el.muted = ...` writes fire the attribute MutationObserver,
        // and our re-application would loop forever without this check.
        function applyOne(el) {
          if (el.muted !== muted) {
            try {
              el.muted = muted;
            } catch (e) {
              console.warn('[e05/mute] el.muted assignment failed', e, el);
            }
          }
        }
        function applyAll() {
          for (const el of document.querySelectorAll('audio, video')) {
            applyOne(el);
          }
        }

        const observer = new MutationObserver((mutations) => {
          for (const m of mutations) {
            if (m.type === 'attributes') {
              // Page script may write `el.muted = false` to bypass our
              // mute (autoplay re-trigger pattern). Re-apply whenever
              // the element's flag disagrees with our intent — both
              // muted and unmuted directions, since unmute also wants
              // the page's stale `true` cleared.
              const el = m.target;
              if (el && (el.tagName === 'AUDIO' || el.tagName === 'VIDEO')) {
                applyOne(el);
              }
              continue;
            }
            if (!muted) continue;
            for (const n of m.addedNodes) {
              if (n.nodeType !== 1) continue;
              if (n.matches && n.matches('audio, video')) applyOne(n);
              if (n.querySelectorAll) {
                for (const el of n.querySelectorAll('audio, video')) {
                  applyOne(el);
                }
              }
            }
          }
        });
        const root = document.documentElement || document;
        observer.observe(root, {
          childList: true,
          subtree: true,
          attributes: true,
          attributeFilter: ['muted'],
        });

        let channel = null;
        try {
          channel = new BroadcastChannel('\(channelId)');
        } catch (e) {
          console.warn(
            '[e05/mute] BroadcastChannel unavailable; cross-frame sync disabled',
            e);
        }
        if (channel) {
          channel.addEventListener('message', (e) => {
            if (e && e.data && typeof e.data.muted === 'boolean'
                && e.data.muted !== muted) {
              muted = e.data.muted;
              applyAll();
            }
          });
        }

        window.__e05_setMuted = (m) => {
          const next = !!m;
          if (next === muted) return;
          muted = next;
          applyAll();
          if (channel) {
            // Surface broadcast failures rather than swallowing them
            // — the page's console is the only diagnostic surface
            // when the cross-frame mute sync silently breaks. The
            // `[e05/mute]` prefix keeps the line greppable and
            // recognisable as e05's own log when devtools is open
            // on a third-party page.
            try {
              channel.postMessage({ muted: muted });
            } catch (e) {
              console.warn('[e05/mute] BroadcastChannel postMessage failed', e);
            }
          }
        };

        // Bitfield audio state probe — tighter than
        // `WKWebView.requestMediaPlaybackState`, which only reports a
        // single coarse enum and counts silent hero videos
        // (`<video autoplay muted>`) as `.playing`. Returns:
        //   bit 0 (1) — at least one media element is actively
        //               playing (regardless of mute / volume); the
        //               UI uses this to keep the speaker glyph
        //               visible on muted-but-active tabs.
        //   bit 1 (2) — at least one element is actually emitting
        //               audio (unmuted, volume > 0); this drives
        //               the "playing" speaker.wave glyph.
        //
        // Known limitations (call sites compensate via the SPI
        // escalation path documented at the call site):
        //  - Web Audio API and WebRTC are out of reach (no DOM
        //    element to walk).
        //  - MediaSession-only PWAs (Spotify Web Player et al.) can
        //    play sound without an `<audio>` / `<video>` element.
        //  - Cross-origin iframes' media is invisible to
        //    `document.querySelectorAll`; the BroadcastChannel sync
        //    only covers same-origin frames.
        window.__e05_audioState = () => {
          let bits = 0;
          for (const el of document.querySelectorAll('audio, video')) {
            if (!el.paused && el.readyState >= 2 && !el.ended) {
              bits |= 1;
              if (!el.muted && el.volume > 0) {
                bits |= 2;
              }
            }
          }
          return bits;
        };
      })();
      """
    return WKUserScript(
      source: source,
      injectionTime: .atDocumentStart,
      forMainFrameOnly: false,
      in: muteContentWorld)
  }

  static let hoverLinkHandlerName = "e05HoverLink"

  /// Content world shared by the hover-link user script and its
  /// message handler. Isolates `window.__e05HoverLinkInstalled`
  /// from page scripts so ad code can't clobber the install guard.
  /// Also reused by ``scrollEdgeContentWorld``; both scripts coexist
  /// behind distinct install guards and distinct message-handler
  /// names. Don't migrate hover-link off `.defaultClient` without
  /// also moving scroll-edge — the routing logic in
  /// ``PaneContainerViewController`` depends on the latter staying
  /// reachable from this world.
  static let hoverLinkContentWorld: WKContentWorld = .defaultClient

  /// Content script that delegates mouse events on `document` to
  /// resolve the nearest ancestor `<a>` with a usable `href` and
  /// reports the resolved URL via the Swift-side message handler.
  /// Injected at document-start in every frame (including same-
  /// origin subframes); the install guard is per content world.
  private static let hoverLinkUserScript = WKUserScript(
    source: """
      (function() {
        if (window.__e05HoverLinkInstalled) return;
        window.__e05HoverLinkInstalled = true;

        // Viewport zone that mirrors where Swift places the preview
        // at the bottom-leading corner. When the cursor enters it,
        // the overlay flips to the trailing edge so a link pinned
        // at the bottom-left stays visible under the cursor. The
        // width is fixed even though the overlay is allowed to grow
        // up to 70% of the pane: on wider panes the overlay may
        // extend past this zone, but since the overlay is click-
        // through and mostly contains a truncated URL, the slight
        // mismatch is acceptable and avoids plumbing pane width
        // into the content script.
        const FLIP_ZONE_WIDTH = 420;
        const FLIP_ZONE_HEIGHT = 44;

        let lastUrl = null;
        let lastSide = 'left';

        function resolveLink(target) {
          if (!target || typeof target.closest !== 'function') return null;
          const a = target.closest('a');
          if (!a) return null;
          const href = a.href;
          if (!href) return null;
          if (href.startsWith('javascript:')) return null;
          // Pure same-page fragment: no preview (matches Safari).
          const raw = a.getAttribute('href');
          if (raw === null || raw === '' || raw === '#') return null;
          // `a.href` returns the fully percent-encoded absolute URL,
          // so `/wiki/日本` comes back as `/wiki/%E6%97%A5%E6%9C%AC`.
          // Decode for display using `decodeURI` — it restores Unicode
          // segments while preserving structural reserved characters
          // like `?`, `#`, `&`, matching how mainstream browsers show
          // URLs in their status bar.
          try {
            return decodeURI(href);
          } catch (e) {
            return href;
          }
        }

        function sideFor(event) {
          // Subframes have their own viewport — `clientX/clientY`
          // and `innerWidth/innerHeight` live in iframe-local
          // coordinates, so the flip zone would be computed
          // against the iframe bounds instead of the pane bounds.
          // Keep the overlay pinned to leading in subframes rather
          // than flipping based on the wrong reference frame.
          if (window.top !== window) return 'left';
          const vw = window.innerWidth || document.documentElement.clientWidth;
          const vh = window.innerHeight || document.documentElement.clientHeight;
          const atLeft = event.clientX < FLIP_ZONE_WIDTH;
          const atBottom = event.clientY > vh - FLIP_ZONE_HEIGHT;
          return (atLeft && atBottom) ? 'right' : 'left';
        }

        function post(url, side) {
          // Skip side-only churn while the preview is hidden:
          // without a url there's nothing to display, so flipping
          // the constraint on every non-link mousemove through the
          // bottom-leading zone would just queue pointless layout
          // passes.
          if (url === null && lastUrl === null) return;
          if (url === lastUrl && side === lastSide) return;
          lastUrl = url;
          lastSide = side;
          try {
            webkit.messageHandlers.e05HoverLink.postMessage({ url: url, side: side });
          } catch (e) { /* handler not yet registered on this frame */ }
        }

        document.addEventListener('mouseover', (e) => {
          post(resolveLink(e.target), sideFor(e));
        }, { passive: true, capture: true });

        document.addEventListener('mousemove', (e) => {
          // Only recompute while a preview is visible: `lastUrl`
          // holds the URL currently displayed by the overlay, so
          // null means the overlay is hidden and no side state
          // needs to be maintained against further mouse motion.
          if (lastUrl === null) return;
          const side = sideFor(e);
          if (side !== lastSide) post(lastUrl, side);
        }, { passive: true, capture: true });

        document.addEventListener('mouseout', (e) => {
          const from = resolveLink(e.target);
          const to = resolveLink(e.relatedTarget);
          if (from && !to) post(null, sideFor(e));
        }, { passive: true, capture: true });
      })();
      """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: false,
    in: hoverLinkContentWorld
  )

  static let scrollEdgeHandlerName = "e05ScrollEdge"

  /// Same world as hover-link so the install guard and message-handler
  /// surface are isolated from page scripts. Reusing `.defaultClient`
  /// is safe — both scripts use distinct install guards and distinct
  /// handler names.
  static let scrollEdgeContentWorld: WKContentWorld = .defaultClient

  /// Content script that snapshots the horizontal overflow state of
  /// whatever scrollable region currently lives under the cursor. The
  /// top document is the fallback, but most modern sites use an inner
  /// `<div overflow-x: scroll>` for their horizontally-scrollable
  /// region (X.com timelines, Discord channel lists, Notion wide
  /// tables, …), so a `document.scrollingElement`-only probe would
  /// misreport every one of them as having no horizontal overflow.
  /// Tracks the cursor target via `mouseover` / `mousemove` / `wheel`
  /// (capture phase to catch synthetic clones), walks ancestors at
  /// probe time to find the nearest element whose computed
  /// `overflow-x` allows scrolling AND has horizontally-overflowing
  /// content, and reports that element's edge state. The `wheel`
  /// listener is what catches the user's first gesture after a focus
  /// move or keyboard-driven action — the cursor may never have
  /// physically traversed the pane, so the snap can't wait for a
  /// mouseover. De-duplicates against the last sent value so a still
  /// cursor and a quiet page don't flood the IPC channel.
  private static let scrollEdgeUserScript = WKUserScript(
    source: """
      (function() {
        if (window.__e05ScrollEdgeInstalled) return;
        window.__e05ScrollEdgeInstalled = true;

        let hoverTarget = null;
        let lastSent = null;

        function findScrollableX(el) {
          const view = (el && el.ownerDocument && el.ownerDocument.defaultView) || window;
          let node = el;
          while (node && node.nodeType === 1) {
            const sw = node.scrollWidth | 0;
            const cw = node.clientWidth | 0;
            if (sw > cw + 1) {
              const ox = view.getComputedStyle(node).overflowX;
              if (ox === 'scroll' || ox === 'auto') return node;
            }
            if (node === node.ownerDocument.documentElement) break;
            node = node.parentNode;
          }
          // Top-level page scroll fallback.
          return document.scrollingElement || document.documentElement;
        }

        function edgeFor(el) {
          if (!el) return 'none';
          const sl = el.scrollLeft | 0;
          const max = (el.scrollWidth - el.clientWidth) | 0;
          if (max <= 1) return 'none';
          if (sl <= 0) return 'right';
          if (sl >= max - 1) return 'left';
          return 'both';
        }

        function snap() {
          const target = hoverTarget ? findScrollableX(hoverTarget)
            : (document.scrollingElement || document.documentElement);
          const edge = edgeFor(target);
          if (edge === lastSent) return;
          lastSent = edge;
          try {
            webkit.messageHandlers.e05ScrollEdge.postMessage(edge);
          } catch (e) { /* handler not yet registered on this frame */ }
        }

        document.addEventListener('mouseover', (e) => {
          hoverTarget = e.target;
          snap();
        }, { passive: true, capture: true });
        document.addEventListener('mousemove', (e) => {
          if (e.target === hoverTarget) return;
          hoverTarget = e.target;
          snap();
        }, { passive: true, capture: true });
        // Cover the gesture-before-any-mouse-event case: just after
        // launch, after a ⌘L / keyboard focus move, or on a trackpad
        // user who keeps the cursor parked while two-finger swiping.
        // The wheel event itself carries the cursor-target element so
        // the snap can resolve the right scrollable ancestor and
        // report an accurate edge before the Swift monitor's `.began`
        // decision runs. Skip when the target is unchanged: wheel
        // fires 60-120 Hz during a continuous gesture and findScrollableX
        // walks ancestors + flushes getComputedStyle on every call.
        // The scroll listener already covers same-target edge updates
        // once the page actually scrolls.
        document.addEventListener('wheel', (e) => {
          if (e.target === hoverTarget) return;
          hoverTarget = e.target;
          snap();
        }, { passive: true, capture: true });
        addEventListener('scroll', snap, { passive: true, capture: true });
        addEventListener('resize', () => { lastSent = null; snap(); });
        document.addEventListener('DOMContentLoaded', () => {
          lastSent = null;
          snap();
        });
        setTimeout(snap, 0);
      })();
      """,
    injectionTime: .atDocumentStart,
    forMainFrameOnly: true,
    in: scrollEdgeContentWorld
  )
}

/// Bridges JS `webkit.messageHandlers.e05HoverLink` posts to a Swift
/// closure. Kept out of ``BrowserPaneView`` so
/// ``WKUserContentController``'s reference can hold on to it without
/// creating a retain cycle with the owning view.
@MainActor
private final class HoverLinkMessageHandler: NSObject, WKScriptMessageHandler {
  var onMessage: ((String?, String?) -> Void)?

  func userContentController(
    _: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == BrowserPaneView.hoverLinkHandlerName else { return }
    let body = message.body as? [String: Any]
    let url = body?["url"] as? String
    let side = body?["side"] as? String
    onMessage?(url, side)
  }
}

/// Bridges JS `webkit.messageHandlers.e05ScrollEdge` posts to a Swift
/// closure. Same retain-strategy as ``HoverLinkMessageHandler``: kept
/// out of ``BrowserPaneView`` so the user content controller can hold
/// a weak reference without creating a retain cycle, and held alive
/// by ``BrowserPaneView.scrollEdgeHandler``.
@MainActor
private final class ScrollEdgeMessageHandler: NSObject, WKScriptMessageHandler {
  var onChange: ((BrowserPaneView.HorizontalScrollEdge) -> Void)?

  func userContentController(
    _: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    guard message.name == BrowserPaneView.scrollEdgeHandlerName else { return }
    guard let raw = message.body as? String,
      let edge = BrowserPaneView.HorizontalScrollEdge(rawValue: raw)
    else { return }
    onChange?(edge)
  }
}

// MARK: - FindHelper

extension BrowserPaneView: FindHelper {
  /// Perform an in-page find for `needle` using a self-contained JS
  /// implementation built on `createTreeWalker` + `Range` + the CSS
  /// Custom Highlight API. WKFindConfiguration isn't used, so
  /// cross-origin iframes contribute neither matches nor highlights
  /// (their DOMs are invisible to us, and skipping them entirely is
  /// what users expect for embedded widgets).
  ///
  /// State between invocations is parked on `window.__e05Find` so
  /// the same needle can be navigated without re-walking the DOM;
  /// changing the needle rebuilds the match array. The JS returns
  /// `{ total, current }` and also applies two highlight layers:
  /// `e05-find` over every match in yellow, `e05-find-current` over
  /// the active one in orange. The DOM selection is moved to the
  /// current match so Copy and screen readers follow along.
  public func performFind(
    _ needle: String,
    forward: Bool,
    completion: @escaping @MainActor ((total: Int, current: Int)) -> Void
  ) {
    guard !needle.isEmpty else {
      endFind()
      Task { @MainActor in completion((0, 0)) }
      return
    }
    webView.callAsyncJavaScript(
      Self.findScript,
      arguments: ["needle": needle, "forward": forward],
      in: nil,
      in: .defaultClient
    ) { result in
      let position: (total: Int, current: Int)
      switch result {
      case .success(let value):
        if let dict = value as? [String: Any] {
          let total = (dict["total"] as? NSNumber)?.intValue ?? 0
          let current = (dict["current"] as? NSNumber)?.intValue ?? 0
          position = (total, current)
        } else {
          position = (0, 0)
        }
      case .failure:
        position = (0, 0)
      }
      Task { @MainActor in completion(position) }
    }
  }

  public func endFind() {
    // Belt-and-braces clear so no painted highlight survives a
    // stale `CSS.highlights` registry entry on Tahoe-era WebKit:
    // 1. Drop the registry entries (the documented kill switch).
    // 2. Remove the injected `<style id="__e05FindStyle">` so the
    //    `::highlight(...)` rules backing any leftover paint go
    //    away with it. The find script's existence guard re-injects
    //    the tag on the next session, so this stays self-healing.
    // 3. Null the `__e05Find` state and clear the selection so the
    //    follow-up session starts from scratch.
    let script = """
      (function() {
        try {
          window.__e05Find = null;
          if (typeof CSS !== 'undefined' && CSS.highlights) {
            CSS.highlights.delete('e05-find');
            CSS.highlights.delete('e05-find-current');
          }
          const style = document.getElementById('__e05FindStyle');
          if (style) style.remove();
          const sel = window.getSelection();
          if (sel) sel.removeAllRanges();
        } catch (e) {}
      })();
      """
    webView.evaluateJavaScript(script, completionHandler: nil)
  }

  /// JavaScript body executed by `callAsyncJavaScript`. `needle` and
  /// `forward` arrive as named arguments. The script collects every
  /// match into a `Range`, paints all-match and current-match
  /// highlight layers, scrolls the current into view, and returns
  /// `{ total, current }` for the Swift side to display.
  private static let findScript: String = """
    if (!document.getElementById('__e05FindStyle')) {
      const style = document.createElement('style');
      style.id = '__e05FindStyle';
      // Tuned for visibility against light-mode page backgrounds:
      // alpha around 0.7 keeps the underlying text legible while
      // making the all-match highlight stand out against white,
      // and the orange current-match stays distinct from the
      // yellow surround. Earlier values (0.45 yellow) blended into
      // light text colours so the all-match layer looked absent.
      style.textContent =
        '::highlight(e05-find) { background-color: rgba(255, 215, 0, 0.7); color: inherit; } ' +
        '::highlight(e05-find-current) { background-color: rgba(255, 140, 0, 0.9); color: inherit; }';
      document.head.appendChild(style);
    }

    function acceptTextNode(node) {
      const parent = node.parentElement;
      if (!parent) return NodeFilter.FILTER_REJECT;
      const tag = parent.nodeName;
      // Reject only text whose parent is a non-rendering element
      // (SCRIPT / STYLE / NOSCRIPT / TEMPLATE) — SEO JSON-LD and
      // stylesheet text that would otherwise inflate the count.
      // Don't add a `checkVisibility` filter here: Safari and
      // Chrome's native find do reach CSS-hidden branches, and any
      // attempt to pre-screen by visibility drops real aside /
      // sidebar / `content-visibility: auto` content that users
      // expect the search to see.
      if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'TEMPLATE') {
        return NodeFilter.FILTER_REJECT;
      }
      return NodeFilter.FILTER_ACCEPT;
    }

    function collect(win, out) {
      try {
        const doc = win.document;
        if (!doc || !doc.body) return;
        const walker = doc.createTreeWalker(
          doc.body,
          NodeFilter.SHOW_TEXT,
          { acceptNode: acceptTextNode }
        );
        const pattern = needle.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
        const re = new RegExp(pattern, 'gi');
        let node;
        while ((node = walker.nextNode())) {
          for (const hit of node.textContent.matchAll(re)) {
            const r = new Range();
            r.setStart(node, hit.index);
            r.setEnd(node, hit.index + hit[0].length);
            out.push(r);
          }
        }
        const iframes = doc.querySelectorAll('iframe');
        for (const iframe of iframes) {
          try {
            const cw = iframe.contentWindow;
            if (cw && cw.document) collect(cw, out);
          } catch (e) {
            // cross-origin — silently skip; those frames contribute
            // nothing to the find session.
          }
        }
      } catch (e) {
        // Swallow any unexpected DOM access error and fall through.
      }
    }

    const state = window.__e05Find;
    let matches;
    if (state && state.needle === needle) {
      matches = state.matches;
    } else {
      matches = [];
      collect(window, matches);
    }

    if (matches.length === 0) {
      if (typeof CSS !== 'undefined' && CSS.highlights) {
        CSS.highlights.delete('e05-find');
        CSS.highlights.delete('e05-find-current');
      }
      window.__e05Find = { needle: needle, matches: matches, current: 0 };
      return { total: 0, current: 0 };
    }

    let current;
    if (state && state.needle === needle && state.current > 0) {
      // Clamp the resume index into the current array length so any
      // future path that rebuilds `matches` shorter cannot leave us
      // stuck past the end. Today's same-needle branch keeps the
      // array identical, so `base === state.current`.
      const base = Math.min(state.current, matches.length);
      if (forward) {
        current = base >= matches.length ? 1 : base + 1;
      } else {
        current = base <= 1 ? matches.length : base - 1;
      }
    } else {
      current = 1;
    }

    const currentRange = matches[current - 1];
    const currentNode = currentRange.startContainer;

    if (typeof CSS !== 'undefined' && CSS.highlights) {
      // Drop any prior registration before installing the new one.
      // `CSS.highlights.set` is documented to replace the highlight
      // at a given key, but WebKit (Tahoe-era) sometimes leaves the
      // previous Range set painted when the registry entry is
      // overwritten with a different match collection — the old
      // needle's hits stay highlighted alongside the new ones.
      // Explicit `delete` before `set` clears the painted state
      // deterministically.
      CSS.highlights.delete('e05-find');
      CSS.highlights.delete('e05-find-current');
      const allHl = new Highlight();
      for (const r of matches) allHl.add(r);
      CSS.highlights.set('e05-find', allHl);
      const curHl = new Highlight();
      curHl.add(currentRange);
      CSS.highlights.set('e05-find-current', curHl);
    }

    // Skip the selection and scroll if the match's container has
    // been detached from the document — dynamic SPA rendering can
    // orphan Ranges cached in window.__e05Find, and scrolling into
    // the orphan jumps to an off-document arbitrary position.
    if (currentNode && currentNode.isConnected) {
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(currentRange);
      const elem = currentNode.parentElement;
      if (elem) elem.scrollIntoView({ block: 'center', behavior: 'smooth' });
    }

    window.__e05Find = { needle: needle, matches: matches, current: current };
    return { total: matches.length, current: current };
    """
}
