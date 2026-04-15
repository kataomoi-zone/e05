import AppKit
import E05Lib

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let ghosttyApp = GhosttyApp()
    private var terminalView: GhosttyTerminalView?

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "e05"
        window.contentMinSize = NSSize(width: 480, height: 320)

        let tv = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 960, height: 640),
            ghosttyApp: ghosttyApp
        )
        tv.autoresizingMask = [.width, .height]
        window.contentView = tv
        self.terminalView = tv

        ghosttyApp.onSetTitle = { [weak self] _, title in
            self?.window?.title = title
        }
        ghosttyApp.onCloseSurface = { [weak self] in
            self?.window?.close()
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(tv)
        NSApp.activate()
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
