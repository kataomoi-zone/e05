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

    /// Whether the URL bar is currently shown.
    public private(set) var isURLBarVisible = false

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
    private var contentTopToURLBarConstraint: NSLayoutConstraint?
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
        case .settings:
            assertionFailure("Settings pane not yet implemented")
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
           !isBlankBrowser {
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
        headerView.translatesAutoresizingMaskIntoConstraints = false

        containerView.addSubview(urlBar)
        containerView.addSubview(cv)
        containerView.addSubview(headerView)

        // URL bar at top
        urlBarTopConstraint = urlBar.topAnchor.constraint(equalTo: containerView.topAnchor)
        let urlBarHeight = urlBar.heightAnchor.constraint(equalToConstant: PaneURLBar.barHeight)

        // Content: either below URL bar or at top of container
        contentTopToURLBarConstraint = cv.topAnchor.constraint(equalTo: urlBar.bottomAnchor)
        contentTopToContainerConstraint = cv.topAnchor.constraint(equalTo: containerView.topAnchor)

        NSLayoutConstraint.activate([
            urlBarTopConstraint!,
            urlBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            urlBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            urlBarHeight,

            cv.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            cv.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            cv.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            // Header overlay (top-right, only shown when URL bar is hidden)
            headerView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
            headerView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 8),
            headerView.heightAnchor.constraint(equalToConstant: 22),
            headerView.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])

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
            contentTopToURLBarConstraint?.isActive = true
        } else {
            contentTopToURLBarConstraint?.isActive = false
            contentTopToContainerConstraint?.isActive = true
        }
    }
}
