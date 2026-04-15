import AppKit

/// Lightweight wrapper around a GhosttyTerminalView for pane management.
@MainActor
public final class PaneModel {
    public let id = UUID()
    public let terminalView: GhosttyTerminalView

    public init(ghosttyApp: GhosttyApp) {
        terminalView = GhosttyTerminalView(frame: .zero, ghosttyApp: ghosttyApp)
    }
}
