import AppKit
import GhosttyTerminal

final class TerminalViewController: NSViewController {
    private lazy var terminalView: TerminalView = .init(
        frame: NSRect(x: 0, y: 0, width: 960, height: 640)
    )

    private lazy var controller: TerminalController = .init { builder in
        builder.withFontSize(14)
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(backend: .exec)
        terminalView.controller = controller
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(terminalView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: view.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(terminalView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        terminalView.fitToSize()
    }
}

extension TerminalViewController:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        view.window?.title = title
    }

    func terminalDidResize(columns _: Int, rows _: Int) {}

    func terminalDidClose(processAlive _: Bool) {
        view.window?.close()
    }
}
