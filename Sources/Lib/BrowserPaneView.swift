import AppKit
import WebKit

/// Pure WKWebView wrapper for browser panes. URL bar is handled by PaneURLBar.
@MainActor
public final class BrowserPaneView: NSView, WKNavigationDelegate {
    public let webView: WKWebView

    /// Called when page title changes.
    public var onTitleChange: ((String) -> Void)?
    /// Called when URL changes.
    public var onURLChange: ((URL?) -> Void)?
    /// Called when back/forward availability changes.
    public var onNavigationStateChange: ((Bool, Bool) -> Void)?

    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var canGoBackObservation: NSKeyValueObservation?
    private var canGoForwardObservation: NSKeyValueObservation?

    public override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)

        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor

        setupWebView()
        setupObservers()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Setup

    private func setupWebView() {
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = NSColor(white: 0.15, alpha: 1.0)
        }
        webView.loadHTMLString(
            "<html><body style='margin:0;background:#262626;'></body></html>",
            baseURL: nil
        )
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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

    // MARK: - Focus

    public override var acceptsFirstResponder: Bool { true }
}
