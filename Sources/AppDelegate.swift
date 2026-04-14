import AppKit
import GhosttyTerminal

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let paneContainer = PaneContainerViewController()

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "e05"
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.contentViewController = paneContainer
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        setupMenuKeyBindings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    // MARK: - Key Bindings via Menu

    private func setupMenuKeyBindings() {
        let mainMenu = NSMenu()

        // App menu (required for ⌘+Q)
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit e05",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Pane menu
        let paneMenuItem = NSMenuItem()
        let paneMenu = NSMenu(title: "Pane")

        let newPaneItem = NSMenuItem(
            title: "New Pane",
            action: #selector(handleNewPane),
            keyEquivalent: "t"
        )
        paneMenu.addItem(newPaneItem)

        let closePaneItem = NSMenuItem(
            title: "Close Pane",
            action: #selector(handleClosePane),
            keyEquivalent: "w"
        )
        paneMenu.addItem(closePaneItem)

        paneMenu.addItem(.separator())

        // ⌥⌃+H: Focus left
        let focusLeftItem = NSMenuItem(
            title: "Focus Left",
            action: #selector(handleFocusLeft),
            keyEquivalent: "h"
        )
        focusLeftItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(focusLeftItem)

        // ⌥⌃+L: Focus right
        let focusRightItem = NSMenuItem(
            title: "Focus Right",
            action: #selector(handleFocusRight),
            keyEquivalent: "l"
        )
        focusRightItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(focusRightItem)

        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @objc private func handleNewPane() {
        paneContainer.addPane()
    }

    @objc private func handleClosePane() {
        paneContainer.removeCurrentPane()
    }

    @objc private func handleFocusLeft() {
        paneContainer.focusLeft()
    }

    @objc private func handleFocusRight() {
        paneContainer.focusRight()
    }
}
