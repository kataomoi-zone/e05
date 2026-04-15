import AppKit
import E05Lib

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let ghosttyApp = GhosttyApp()
    private var paneContainer: PaneContainerViewController?

    func applicationDidFinishLaunching(_: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "e05"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        // Hide traffic lights — e05 manages pane lifecycle via ⌘+W/⌘+Q
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 480, height: 320)

        let container = PaneContainerViewController(ghosttyApp: ghosttyApp)
        window.contentViewController = container
        self.paneContainer = container

        ghosttyApp.onSetTitle = { [weak container] surface, title in
            container?.handleTitleChange(surface: surface, title: title)
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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

        paneMenu.addItem(.separator())

        // ⌥⌃+Shift+H: Move pane left
        let movePaneLeftItem = NSMenuItem(
            title: "Move Pane Left",
            action: #selector(handleMovePaneLeft),
            keyEquivalent: "h"
        )
        movePaneLeftItem.keyEquivalentModifierMask = [.option, .control, .shift]
        paneMenu.addItem(movePaneLeftItem)

        // ⌥⌃+Shift+L: Move pane right
        let movePaneRightItem = NSMenuItem(
            title: "Move Pane Right",
            action: #selector(handleMovePaneRight),
            keyEquivalent: "l"
        )
        movePaneRightItem.keyEquivalentModifierMask = [.option, .control, .shift]
        paneMenu.addItem(movePaneRightItem)

        paneMenu.addItem(.separator())

        // ⌥⌃+/: Cycle width preset
        let cycleWidthItem = NSMenuItem(
            title: "Cycle Width",
            action: #selector(handleCycleWidth),
            keyEquivalent: "/"
        )
        cycleWidthItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(cycleWidthItem)

        // ⌥⌃+T: Toggle header visibility
        let toggleHeaderItem = NSMenuItem(
            title: "Toggle Header",
            action: #selector(handleToggleHeader),
            keyEquivalent: "t"
        )
        toggleHeaderItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(toggleHeaderItem)

        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Default Width Cycle

    private let defaultWidthCycle: [PaneWidthPreset] = [
        .columns(80),
        .columns(120),
        .fraction(1.0 / 2.0),
        .fraction(1.0 / 3.0),
    ]

    // MARK: - Actions

    @objc private func handleNewPane() {
        paneContainer?.addPane()
    }

    @objc private func handleClosePane() {
        paneContainer?.removeCurrentPane()
    }

    @objc private func handleFocusLeft() {
        paneContainer?.focusLeft()
    }

    @objc private func handleFocusRight() {
        paneContainer?.focusRight()
    }

    @objc private func handleMovePaneLeft() {
        paneContainer?.movePaneLeft()
    }

    @objc private func handleMovePaneRight() {
        paneContainer?.movePaneRight()
    }

    @objc private func handleCycleWidth() {
        paneContainer?.cycleWidthPreset(defaultWidthCycle)
    }

    @objc private func handleToggleHeader() {
        paneContainer?.toggleHeaderVisibility()
    }
}
