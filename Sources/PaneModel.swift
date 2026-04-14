import AppKit
import GhosttyTerminal

@MainActor
final class PaneModel {
    let id = UUID()
    let terminalView: TerminalView
    private let delegateProxy: PaneDelegateProxy

    init(controller: TerminalController, onTitle: @escaping (UUID, String) -> Void, onClose: @escaping (UUID) -> Void) {
        terminalView = TerminalView(frame: .zero)
        terminalView.configuration = TerminalSurfaceOptions(backend: .exec)
        terminalView.controller = controller

        delegateProxy = PaneDelegateProxy(paneID: id, onTitle: onTitle, onClose: onClose)
        terminalView.delegate = delegateProxy
    }
}

/// Per-pane delegate proxy that captures the pane ID and forwards
/// terminal events with sender identification.
@MainActor
private final class PaneDelegateProxy: NSObject,
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate
{
    let paneID: UUID
    let onTitle: (UUID, String) -> Void
    let onClose: (UUID) -> Void

    init(paneID: UUID, onTitle: @escaping (UUID, String) -> Void, onClose: @escaping (UUID) -> Void) {
        self.paneID = paneID
        self.onTitle = onTitle
        self.onClose = onClose
    }

    func terminalDidChangeTitle(_ title: String) {
        onTitle(paneID, title)
    }

    func terminalDidResize(columns _: Int, rows _: Int) {}

    func terminalDidClose(processAlive _: Bool) {
        onClose(paneID)
    }
}
