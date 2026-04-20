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
        // Fire off the extension load before the first browser pane is
        // constructed. Scanning the extensions directory is cheap and the
        // actual WKWebExtension parsing runs asynchronously, so this does
        // not block window creation. Panes that come up before loadAll()
        // finishes still reach the fully configured controller — only the
        // set of loaded contexts grows once scanning completes.
        Task { await ExtensionController.shared.loadAll() }

        // Prime the built-in content rule list. On first launch the
        // filterlist is downloaded and compiled in the background, so
        // panes created before compilation completes get no blocker this
        // session. Subsequent launches pull the compiled binary from
        // WKContentRuleListStore synchronously and apply immediately.
        Task { await AdBlocker.shared.start() }

        // Lock the app to dark aqua so every NSView inherits a dark
        // effective appearance regardless of the system setting. The
        // browser panes render dark content anyway, so a light chrome
        // around them looks out of place. A future preference (follow
        // system / force light / force dark) can replace this line; the
        // sidebar's `viewDidChangeEffectiveAppearance` path already
        // tracks appearance changes.
        NSApp.appearance = NSAppearance(named: .darkAqua)

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
        // Traffic lights stay at their OS default position; the sidebar
        // header renders underneath them via `titlebarAppearsTransparent`
        // + `fullSizeContentView`. Button visibility is driven by the
        // sidebar state machine (see `applyTrafficLights`).
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
