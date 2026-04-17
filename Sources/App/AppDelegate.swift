import AppKit
import E05Lib

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow?
    private let ghosttyApp = GhosttyApp()
    private var paneContainer: PaneContainerViewController?
    /// Actions retrieved from the pane container, cached at menu-build time.
    /// Indexed by `NSMenuItem.tag` (= position in the actions array) so that
    /// `validateMenuItem` and `performAction` can look up the right entry in
    /// O(1) without iterating or string matching.
    ///
    /// Single-window assumption: the array is built once from the sole
    /// `paneContainer` and never refreshed. If multi-window support is
    /// added, this cache must become per-window (or re-fetched on focus
    /// change) because the handler closures capture `[weak paneContainer]`.
    /// The tag-based index also assumes a static action order — dynamic
    /// action lists would require id-based lookup instead.
    private var actions: [Action] = []

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

    func applicationWillTerminate(_: Notification) {
        paneContainer?.saveSession()
    }

    // MARK: - Menu Construction from Action Registry

    private func setupMenuKeyBindings() {
        let mainMenu = NSMenu()

        // App menu (required for ⌘+Q) — not Action-driven because
        // NSApplication.terminate is a framework selector, not a pane op.
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit e05",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Pane menu — built from the Action registry.
        let paneMenuItem = NSMenuItem()
        let paneMenu = NSMenu(title: "Pane")

        self.actions = paneContainer?.actions() ?? []
        for (index, action) in actions.enumerated() {
            if action.separatorBefore {
                paneMenu.addItem(.separator())
            }
            let item = NSMenuItem(
                title: action.title,
                action: #selector(performAction(_:)),
                keyEquivalent: action.keyEquivalent ?? ""
            )
            item.keyEquivalentModifierMask = action.modifierMask
            item.tag = index
            paneMenu.addItem(item)
        }

        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // Edit menu — standard text editing actions (⌘+A, ⌘+C, ⌘+V, ⌘+X).
        // These dispatch via the responder chain: NSTextField handles them
        // when focused; GhosttyTerminalView does not respond, so the items
        // auto-disable and ⌘+V falls through to ghostty's own keybind.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(performAction(_:)),
              actions.indices.contains(menuItem.tag) else {
            return true
        }
        let action = actions[menuItem.tag]
        guard let validate = action.validate else { return true }
        let result = validate()
        if let title = result.title {
            menuItem.title = title
        }
        return result.enabled
    }

    // MARK: - Unified Action Dispatch

    @objc private func performAction(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].handler()
    }
}
