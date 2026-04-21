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
    let focusReportingWebView = FocusReportingWebView(frame: .zero, configuration: config)
    webView = focusReportingWebView

    super.init(frame: frame)
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
}

// MARK: - FindHelper

extension BrowserPaneView: FindHelper {
  public func performFind(_ needle: String, forward: Bool) {
    guard !needle.isEmpty else {
      endFind()
      return
    }
    let config = WKFindConfiguration()
    config.backwards = !forward
    config.wraps = true
    webView.find(needle, configuration: config) { _ in
      // The boolean `matchFound` result is ignored here. Surfacing it
      // back to the find bar (for a no-match red tint, for instance)
      // is a future extension.
    }
  }

  public func endFind() {
    // WKWebView exposes no public API to clear an in-page find
    // highlight. Existing highlights dissipate when the page navigates
    // or reloads; immediate clearing on close (to match Safari) would
    // require injecting JavaScript that strips the selection and any
    // `-webkit-text-highlight` styling, and is deferred until the find
    // bar gains an incremental JS channel.
  }

  /// Query the current find position (total hits, and the 1-based
  /// index of whichever match the live selection currently occupies)
  /// for `needle`. Walks every text node via
  /// `document.createTreeWalker`, sums `matchAll` hits, and
  /// cross-references `window.getSelection()` in each frame to
  /// identify the currently focused match.
  ///
  /// The walker recurses into every same-origin iframe so nested
  /// DOMs still contribute to the total. Cross-origin iframes
  /// (Twitter embeds, YouTube players, sandboxed widgets) can't be
  /// walked because the same-origin policy makes `contentWindow`
  /// accessors throw; those frames are silently skipped. Their hits
  /// are still highlighted on screen by `WKFindConfiguration`, so
  /// the visible selection can land in a cross-origin frame — in
  /// that case the returned `current` is 0 (JS sees nothing) and
  /// the Swift side retains its last known position.
  public func queryMatchPosition(
    _ needle: String,
    completion: @escaping @MainActor ((total: Int, current: Int)) -> Void
  ) {
    guard !needle.isEmpty else {
      Task { @MainActor in completion((0, 0)) }
      return
    }
    let script = """
      const pattern = needle.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&');
      const re = new RegExp(pattern, 'gi');
      function walk(win, offset) {
        let total = offset;
        let current = 0;
        try {
          const doc = win.document;
          if (!doc || !doc.body) return { total: total, current: current };
          const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
          const sel = win.getSelection();
          const range = sel && sel.rangeCount > 0 ? sel.getRangeAt(0) : null;
          let node;
          while ((node = walker.nextNode())) {
            for (const hit of node.textContent.matchAll(re)) {
              total += 1;
              if (current === 0 && range && node === range.startContainer) {
                const ms = hit.index;
                const me = ms + hit[0].length;
                if (range.startOffset >= ms && range.startOffset <= me) {
                  current = total;
                }
              }
            }
          }
        } catch (e) {
          return { total: total, current: current };
        }
        try {
          const iframes = win.document.querySelectorAll('iframe');
          for (const iframe of iframes) {
            try {
              const cw = iframe.contentWindow;
              if (cw && cw.document) {
                const sub = walk(cw, total);
                total = sub.total;
                if (current === 0 && sub.current > 0) {
                  current = sub.current;
                }
              }
            } catch (e) {
              // cross-origin — silently skip; those hits remain
              // highlighted by WKFindConfiguration but unreachable.
            }
          }
        } catch (e) {
          // `querySelectorAll` should never throw on a live
          // document, but guard anyway so the outer walk always
          // returns sensible numbers.
        }
        return { total: total, current: current };
      }
      return walk(window, 0);
      """
    webView.callAsyncJavaScript(
      script,
      arguments: ["needle": needle],
      in: nil,
      in: .defaultClient
    ) { result in
      let position: (total: Int, current: Int)
      switch result {
      case .success(let value):
        if let dict = value as? [String: Any] {
          // JavaScript numbers bridge back as NSNumber — NSNumber
          // handles Int / Double / Bool uniformly where `as? Int`
          // alone can be environment-dependent.
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
}
