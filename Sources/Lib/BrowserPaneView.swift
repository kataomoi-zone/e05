import AppKit
import WebKit

/// Container view for a browser pane: URL bar + navigation buttons + WKWebView.
@MainActor
public final class BrowserPaneView: NSView, WKNavigationDelegate, NSTextFieldDelegate {
    public let webView: WKWebView
    private let urlBar: NSTextField
    private let backButton: NSButton
    private let forwardButton: NSButton
    private let toolbarHeight: CGFloat = 28

    /// Called when page title changes.
    public var onTitleChange: ((String) -> Void)?
    /// Called when URL changes.
    public var onURLChange: ((URL?) -> Void)?

    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?

    public override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        urlBar = NSTextField()
        backButton = NSButton(title: "\u{25C0}", target: nil, action: nil)
        forwardButton = NSButton(title: "\u{25B6}", target: nil, action: nil)

        super.init(frame: frame)
        wantsLayer = true
        // Force dark appearance for all child controls (buttons, text fields, field editors)
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor

        setupToolbar()
        setupWebView()
        setupObservers()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Setup

    private func setupToolbar() {
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.bezelStyle = .inline
        backButton.isBordered = false
        backButton.font = .systemFont(ofSize: 12)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        forwardButton.target = self
        forwardButton.action = #selector(goForward)
        forwardButton.bezelStyle = .inline
        forwardButton.isBordered = false
        forwardButton.font = .systemFont(ofSize: 12)
        forwardButton.translatesAutoresizingMaskIntoConstraints = false

        urlBar.placeholderString = "Enter URL..."
        urlBar.font = .systemFont(ofSize: 12)
        urlBar.delegate = self
        urlBar.translatesAutoresizingMaskIntoConstraints = false
        urlBar.focusRingType = .none
        urlBar.cell?.isScrollable = true

        addSubview(backButton)
        addSubview(forwardButton)
        addSubview(urlBar)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: urlBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: urlBar.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 24),

            urlBar.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            urlBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            urlBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            urlBar.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func setupWebView() {
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = NSColor(white: 0.15, alpha: 1.0)
        }
        // Dark blank page instead of white default
        webView.loadHTMLString(
            "<html><body style='margin:0;background:#262626;'></body></html>",
            baseURL: nil
        )
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor, constant: toolbarHeight),
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
            DispatchQueue.main.async {
                self?.urlBar.stringValue = url.absoluteString
                self?.onURLChange?(url)
            }
        }
    }

    // MARK: - Navigation

    @objc private func goBack() {
        webView.goBack()
    }

    @objc private func goForward() {
        webView.goForward()
    }

    public func navigate(to urlString: String) {
        var normalized = urlString.trimmingCharacters(in: .whitespaces)
        if !normalized.contains("://") {
            normalized = "https://" + normalized
        }
        guard let url = URL(string: normalized),
              let scheme = url.scheme,
              ["https", "http"].contains(scheme)
        else { return }
        webView.load(URLRequest(url: url))
    }

    // MARK: - NSTextFieldDelegate

    public func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) {
            navigate(to: urlBar.stringValue)
            // Return focus to webView after navigation
            window?.makeFirstResponder(webView)
            return true
        }
        return false
    }

    // MARK: - Focus

    public override var acceptsFirstResponder: Bool { true }

}
