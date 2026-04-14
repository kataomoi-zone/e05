import AppKit
import GhosttyTerminal

@MainActor
final class PaneModel {
    let id = UUID()
    let terminalView: TerminalView

    init(controller: TerminalController) {
        terminalView = TerminalView(frame: .zero)
        terminalView.configuration = TerminalSurfaceOptions(backend: .exec)
        terminalView.controller = controller
    }
}
