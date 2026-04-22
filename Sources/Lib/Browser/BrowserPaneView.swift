import AppKit
import WebKit

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
public final class BrowserPaneView: NSView, WKNavigationDelegate {
  public let webView: WKWebView

  /// Container for webView + Inspector. WebKit manages the split inside this.
  private let browserHostView = NSView()

  /// Status-bar-style preview that shows the URL under the cursor
  /// while the user hovers a link. Populated by the JS content script
  /// registered in ``init(frame:)``.
  public let hoverLinkOverlay = HoverLinkOverlayView()

  /// Retained so the `WKUserContentController`'s weak handler
  /// reference has something to point at. Without a strong reference
  /// here the handler would be released the moment ``init`` returns.
  private let hoverLinkMessageHandler: HoverLinkMessageHandler

  /// Paired horizontal constraints for ``hoverLinkOverlay``. Only
  /// one is active at any time; the JS content script decides which
  /// side the preview should live on based on the cursor position.
  private var hoverLinkOverlayLeadingConstraint: NSLayoutConstraint?
  private var hoverLinkOverlayTrailingConstraint: NSLayoutConstraint?

  /// Called when page title changes.
  public var onTitleChange: ((String) -> Void)?
  /// Called when URL changes.
  public var onURLChange: ((URL?) -> Void)?
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

  private var titleObservation: NSKeyValueObservation?
  private var urlObservation: NSKeyValueObservation?
  private var canGoBackObservation: NSKeyValueObservation?
  private var canGoForwardObservation: NSKeyValueObservation?
  private var isLoadingObservation: NSKeyValueObservation?
  private var adblockerObserverTask: Task<Void, Never>?

  public override init(frame: NSRect) {
    let config = WKWebViewConfiguration()
    // Enable Web Inspector — required for _inspector to work.
    config.preferences.setValue(true, forKey: "developerExtrasEnabled")
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
    let hoverHandler = HoverLinkMessageHandler()
    config.userContentController.addUserScript(Self.hoverLinkUserScript)
    config.userContentController.add(
      hoverHandler,
      contentWorld: Self.hoverLinkContentWorld,
      name: Self.hoverLinkHandlerName
    )
    hoverLinkMessageHandler = hoverHandler
    let focusReportingWebView = FocusReportingWebView(frame: .zero, configuration: config)
    webView = focusReportingWebView

    super.init(frame: frame)

    hoverHandler.onMessage = { [weak self] url, side in
      guard let self else { return }
      self.applyHoverLinkSide(side)
      if let url, !url.isEmpty {
        self.hoverLinkOverlay.show(url: url)
      } else {
        self.hoverLinkOverlay.hide()
      }
    }
    wantsLayer = true
    appearance = NSAppearance(named: .darkAqua)
    layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor

    focusReportingWebView.onFocusGained = { [weak self] in
      self?.onFocusChanged?()
    }

    setupHostAndWebView()
    setupObservers()
    observeAdBlockerReady()
  }

  /// When the pane is built before ``AdBlocker.shared`` finishes its
  /// first-run compile, subscribe to the global ready notification and
  /// attach the rule lists to the live ``WKUserContentController``
  /// exactly once. ``WKUserContentController`` accepts post-init
  /// ``add(_:)`` calls for rule lists (unlike the configuration, which
  /// is snapshotted at web view init).
  private func observeAdBlockerReady() {
    if !AdBlocker.shared.ruleLists.isEmpty { return }
    let ucc = webView.configuration.userContentController
    adblockerObserverTask = Task { @MainActor [weak self] in
      let stream = NotificationCenter.default.notifications(
        named: AdBlocker.ruleListDidChangeNotification,
        object: nil
      )
      for await _ in stream {
        // If the pane has been released, abandon the stream
        // rather than wait for further notifications that will
        // never matter.
        guard self != nil else { return }
        let lists = AdBlocker.shared.ruleLists
        guard !lists.isEmpty else { continue }
        for list in lists {
          ucc.add(list)
        }
        return
      }
    }
  }

  deinit {
    adblockerObserverTask?.cancel()
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

    // webView uses autoresizing mask inside browserHostView (not Auto Layout).
    // This lets WebKit manage webView.frame directly when Inspector is attached.
    webView.navigationDelegate = self
    webView.translatesAutoresizingMaskIntoConstraints = true
    webView.autoresizingMask = [.width, .height]
    webView.frame = browserHostView.bounds
    webView.underPageBackgroundColor = NSColor(white: 0.15, alpha: 1.0)
    webView.loadHTMLString(
      "<html><body style='margin:0;background:#262626;'></body></html>",
      baseURL: nil
    )
    browserHostView.addSubview(webView)
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
      DispatchQueue.main.async { self?.onURLChange?(url) }
    }
    canGoBackObservation = webView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.onNavigationStateChange?(self.webView.canGoBack, self.webView.canGoForward)
      }
    }
    canGoForwardObservation = webView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.onNavigationStateChange?(self.webView.canGoBack, self.webView.canGoForward)
      }
    }
    isLoadingObservation = webView.observe(\.isLoading, options: [.new, .initial]) { [weak self] _, change in
      guard let isLoading = change.newValue else { return }
      DispatchQueue.main.async { self?.onLoadingStateChange?(isLoading) }
    }
  }

  // MARK: - Navigation

  public func navigate(to urlString: String) {
    var normalized = urlString.trimmingCharacters(in: .whitespaces)
    // about: scheme uses "about:blank" format (no "://")
    if !normalized.contains("://"), !normalized.hasPrefix("about:") {
      normalized = "https://" + normalized
    }
    guard let url = URL(string: normalized),
      let scheme = url.scheme,
      ["https", "http", "about"].contains(scheme)
    else { return }
    webView.load(URLRequest(url: url))
  }

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
      NSLog("[e05-browser] _inspector not available")
      return
    }
    // Update state BEFORE side effects so layout() sees the correct value during reentrant calls
    if isInspectorOpen {
      isInspectorOpen = false
      inspector.perform(InspectorSelector.close)
      webView.frame = browserHostView.bounds
      NSLog("[e05-browser] Inspector closed")
    } else {
      isInspectorOpen = true
      // attach BEFORE show so Inspector opens inline from the start
      // (avoids the flash of a separate window when remembered state is detached)
      inspector.perform(InspectorSelector.attach)
      inspector.perform(InspectorSelector.show)
      NSLog("[e05-browser] Inspector opened (inline)")
    }
  }

  // MARK: - Focus

  public override var acceptsFirstResponder: Bool { true }

  // MARK: - Download Interception

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

  public func webView(
    _: WKWebView,
    navigationResponse _: WKNavigationResponse,
    didBecome download: WKDownload
  ) {
    onDownloadStarted?(download)
  }

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

  static let hoverLinkHandlerName = "e05HoverLink"

  /// Content world shared by the hover-link user script and its
  /// message handler. Isolates `window.__e05HoverLinkInstalled`
  /// from page scripts so ad code can't clobber the install guard.
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
    let script = """
      window.__e05Find = null;
      if (typeof CSS !== 'undefined' && CSS.highlights) {
        CSS.highlights.delete('e05-find');
        CSS.highlights.delete('e05-find-current');
      }
      const sel = window.getSelection();
      if (sel) sel.removeAllRanges();
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
      style.textContent =
        '::highlight(e05-find) { background-color: rgba(255, 255, 0, 0.45); color: inherit; } ' +
        '::highlight(e05-find-current) { background-color: rgba(255, 128, 0, 0.75); color: inherit; }';
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
