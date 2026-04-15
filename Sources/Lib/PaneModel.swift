import AppKit

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
    public let id = UUID()
    public let content: PaneContent

    /// Terminal title or page title.
    public var title: String = ""

    /// Overlay header showing the title.
    public let headerView = PaneHeaderView()

    // TODO: used for vertical drag resize (Step 5)
    public var heightConstraint: NSLayoutConstraint?

    /// The NSView to add to the layout. Works for both terminal and browser.
    public var contentView: NSView {
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

    /// The view that should become first responder when this pane is focused.
    public var preferredFirstResponder: NSView {
        switch content {
        case .terminal(let tv): return tv
        case .browser(let bv): return bv.webView
        }
    }

    /// Create a terminal pane.
    public init(ghosttyApp: GhosttyApp) {
        let tv = GhosttyTerminalView(frame: .zero, ghosttyApp: ghosttyApp)
        tv.translatesAutoresizingMaskIntoConstraints = false
        self.content = .terminal(tv)
        setupHeaderView()
    }

    /// Create a browser pane.
    public init(browser: Void = ()) {
        let bv = BrowserPaneView()
        bv.translatesAutoresizingMaskIntoConstraints = false
        self.content = .browser(bv)
        setupHeaderView()
    }

    private func setupHeaderView() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            headerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            headerView.heightAnchor.constraint(equalToConstant: 22),
            headerView.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }
}
