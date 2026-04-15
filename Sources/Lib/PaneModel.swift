import AppKit

/// Preset for pane width. Each cycle action defines an ordered list of these.
public enum PaneWidthPreset: Equatable {
    case columns(Int)
    case fraction(CGFloat)
}

/// Lightweight wrapper around a GhosttyTerminalView for pane management.
@MainActor
public final class PaneModel {
    public let id = UUID()
    public let terminalView: GhosttyTerminalView

    /// Currently applied width preset. nil = default fixed width (no preset active).
    public var currentPreset: PaneWidthPreset?
    /// Reference to the width constraint for dynamic updates.
    public var widthConstraint: NSLayoutConstraint?

    /// Terminal title from SET_TITLE action.
    public var title: String = ""

    /// Overlay header showing the title.
    public let headerView = PaneHeaderView()

    public init(ghosttyApp: GhosttyApp) {
        terminalView = GhosttyTerminalView(frame: .zero, ghosttyApp: ghosttyApp)
        setupHeaderView()
    }

    private func setupHeaderView() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor, constant: -8),
            headerView.topAnchor.constraint(equalTo: terminalView.topAnchor, constant: 8),
            headerView.heightAnchor.constraint(equalToConstant: 22),
            headerView.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }
}
