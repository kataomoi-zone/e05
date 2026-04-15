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

        let newColumnItem = NSMenuItem(
            title: "New Column",
            action: #selector(handleNewColumn),
            keyEquivalent: "t"
        )
        paneMenu.addItem(newColumnItem)

        let closePaneItem = NSMenuItem(
            title: "Close Pane",
            action: #selector(handleClosePane),
            keyEquivalent: "w"
        )
        paneMenu.addItem(closePaneItem)

        // ⌥⌃+V: Split vertical
        let splitVerticalItem = NSMenuItem(
            title: "Split Vertical",
            action: #selector(handleSplitVertical),
            keyEquivalent: "v"
        )
        splitVerticalItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(splitVerticalItem)

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

        // ⌥⌃+J: Focus down
        let focusDownItem = NSMenuItem(
            title: "Focus Down",
            action: #selector(handleFocusDown),
            keyEquivalent: "j"
        )
        focusDownItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(focusDownItem)

        // ⌥⌃+K: Focus up
        let focusUpItem = NSMenuItem(
            title: "Focus Up",
            action: #selector(handleFocusUp),
            keyEquivalent: "k"
        )
        focusUpItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(focusUpItem)

        paneMenu.addItem(.separator())

        // ⌥⌃+Shift+H: Move column left
        let moveColumnLeftItem = NSMenuItem(
            title: "Move Column Left",
            action: #selector(handleMoveColumnLeft),
            keyEquivalent: "h"
        )
        moveColumnLeftItem.keyEquivalentModifierMask = [.option, .control, .shift]
        paneMenu.addItem(moveColumnLeftItem)

        // ⌥⌃+Shift+L: Move column right
        let moveColumnRightItem = NSMenuItem(
            title: "Move Column Right",
            action: #selector(handleMoveColumnRight),
            keyEquivalent: "l"
        )
        moveColumnRightItem.keyEquivalentModifierMask = [.option, .control, .shift]
        paneMenu.addItem(moveColumnRightItem)

        // ⌥⌃+Shift+J: Move pane down
        let movePaneDownItem = NSMenuItem(
            title: "Move Pane Down",
            action: #selector(handleMovePaneDown),
            keyEquivalent: "j"
        )
        movePaneDownItem.keyEquivalentModifierMask = [.option, .control, .shift]
        paneMenu.addItem(movePaneDownItem)

        // ⌥⌃+Shift+K: Move pane up
        let movePaneUpItem = NSMenuItem(
            title: "Move Pane Up",
            action: #selector(handleMovePaneUp),
            keyEquivalent: "k"
        )
        movePaneUpItem.keyEquivalentModifierMask = [.option, .control, .shift]
        paneMenu.addItem(movePaneUpItem)

        paneMenu.addItem(.separator())

        // ⌥⌃+/: Cycle width preset
        let cycleWidthItem = NSMenuItem(
            title: "Cycle Width",
            action: #selector(handleCycleWidth),
            keyEquivalent: "/"
        )
        cycleWidthItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(cycleWidthItem)

        // ⌘+Shift+L: Toggle URL bar visibility
        let toggleURLBarItem = NSMenuItem(
            title: "Toggle URL Bar",
            action: #selector(handleToggleURLBar),
            keyEquivalent: "l"
        )
        toggleURLBarItem.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(toggleURLBarItem)

        // ⌘+L: Focus URL bar
        let focusURLBarItem = NSMenuItem(
            title: "Focus URL Bar",
            action: #selector(handleFocusURLBar),
            keyEquivalent: "l"
        )
        paneMenu.addItem(focusURLBarItem)

        // ⌥⌃+B: New Browser Column
        let newBrowserItem = NSMenuItem(
            title: "New Browser Column",
            action: #selector(handleNewBrowser),
            keyEquivalent: "b"
        )
        newBrowserItem.keyEquivalentModifierMask = [.option, .control]
        paneMenu.addItem(newBrowserItem)

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

    @objc private func handleNewColumn() {
        paneContainer?.addColumn()
    }

    @objc private func handleClosePane() {
        paneContainer?.removeCurrentPane()
    }

    @objc private func handleSplitVertical() {
        paneContainer?.splitVertical()
    }

    @objc private func handleFocusLeft() {
        paneContainer?.focusLeft()
    }

    @objc private func handleFocusRight() {
        paneContainer?.focusRight()
    }

    @objc private func handleFocusDown() {
        paneContainer?.focusDown()
    }

    @objc private func handleFocusUp() {
        paneContainer?.focusUp()
    }

    @objc private func handleMoveColumnLeft() {
        paneContainer?.moveColumnLeft()
    }

    @objc private func handleMoveColumnRight() {
        paneContainer?.moveColumnRight()
    }

    @objc private func handleMovePaneDown() {
        paneContainer?.movePaneDown()
    }

    @objc private func handleMovePaneUp() {
        paneContainer?.movePaneUp()
    }

    @objc private func handleCycleWidth() {
        paneContainer?.cycleWidthPreset(defaultWidthCycle)
    }

    @objc private func handleToggleURLBar() {
        paneContainer?.toggleURLBarVisibility()
    }

    @objc private func handleFocusURLBar() {
        paneContainer?.focusURLBar()
    }

    @objc private func handleNewBrowser() {
        paneContainer?.addColumn(address: .blankBrowser)
    }
}
