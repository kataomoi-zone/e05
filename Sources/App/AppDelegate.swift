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

  /// Handle returned by `addLocalMonitorForEvents`. Held so a
  /// re-entrant `applicationDidFinishLaunching` (test harness, state
  /// restoration) doesn't stack monitors, and so `removeMonitor`
  /// can pair against `installTabKeyMonitor` cleanly.
  private var tabKeyMonitor: Any?

  /// Same handle pattern as `tabKeyMonitor` but for the extension
  /// command dispatcher. Without this, `chrome.commands` shortcuts
  /// declared in MV3 manifests (e.g. Bitwarden's Cmd+Shift+L
  /// autofill) never reach `WKWebExtensionContext.performCommand`
  /// and the keystroke just rings the system bell.
  private var extensionCommandMonitor: Any?

  func applicationDidFinishLaunching(_: Notification) {
    // Prime the built-in content rule list. On first launch the
    // filterlist is downloaded and compiled in the background, so
    // panes created before compilation completes get no blocker this
    // session. Subsequent launches pull the compiled binary from
    // WKContentRuleListStore synchronously and apply immediately.
    //
    // CosmeticFilterEngine runs sequentially after so it can read the
    // same filter text from disk rather than double-downloading. The
    // cosmetic index is applied through a WKUserScript per-pane and
    // has no per-launch compile cost; its cold-start penalty is just
    // parsing the shared cache.
    Task {
      await AdBlocker.shared.start()
      await CosmeticFilterEngine.shared.start()
    }

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

    // Bind the container to the extension bridge BEFORE kicking off
    // `loadAll()`. The web-extension controller seeds its `openTabs`
    // set once at extension load by walking
    // `openWindowsFor → tabs(for:)`, and a missed binding leaves
    // every loaded extension with an empty tab view that never
    // recovers. `loadAll()` runs as a Task whose first MainActor hop
    // happens after `applicationDidFinishLaunching` returns, so
    // simply ordering the synchronous bind call before the Task
    // creation is enough to win the race.
    ExtensionController.shared.bindContainer(container)
    Task { await ExtensionController.shared.loadAll() }

    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    self.window = window

    setupMenuKeyBindings()
    installTabKeyMonitor()
    installExtensionCommandMonitor()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
    true
  }

  func applicationWillTerminate(_: Notification) {
    paneContainer?.saveSession()
    // Native messaging hosts (Bitwarden's `desktop_proxy`, etc.)
    // are spawned per `chrome.runtime.connectNative` call and stay
    // alive as long as the e05 process holds the port. Without an
    // explicit teardown the children inherit no parent and become
    // orphans until the user logs out.
    ExtensionController.shared.shutdownAllNativePorts()
  }

  // MARK: - Tab Key Monitor
  //
  // AppKit reserves the Tab key for the key-view loop
  // (`selectNextKeyView:` / `selectPreviousKeyView:`), and that
  // claim runs ahead of NSMenu's key-equivalent dispatch — so a
  // menu item with `keyEquivalent: "\t"` never fires regardless of
  // the modifier mask. Hook the keyDown stream directly so the
  // ⌃⇥ / ⌃⇧⇥ pane-cycle gestures work like every other shortcut.
  // The Action entries still own the menu/palette presentation;
  // this monitor only rescues their dispatch.

  private func installTabKeyMonitor() {
    if let existing = tabKeyMonitor {
      NSEvent.removeMonitor(existing)
      tabKeyMonitor = nil
    }
    tabKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self,
        // 0x30 is Apple's virtual key code for Tab on standard
        // layouts. Layout switches (JIS, Dvorak) keep the same
        // physical-position mapping, but third-party remappers
        // like Karabiner-Elements can override it — those setups
        // are unverified here.
        event.keyCode == 0x30
      else { return event }
      let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      // Only handle plain ⌃⇥ / ⌃⇧⇥. Letting ⌘⇥ / ⌥⇥ through keeps
      // the OS-level app switcher and any future option-tab keymap
      // intact.
      guard mods == .control || mods == [.control, .shift] else { return event }
      let shifted = mods.contains(.shift)
      guard let pc = self.paneContainer else { return event }
      if shifted {
        pc.focusPreviousPane()
      } else {
        pc.focusNextPane()
      }
      // Returning nil consumes the event so the responder chain
      // doesn't go on to process Tab as a key-view loop step.
      return nil
    }
  }

  /// Hand keyDown events to every loaded extension's command map
  /// before they reach the responder chain. WKWebExtensionContext
  /// only invokes `chrome.commands.onCommand` listeners when the
  /// host explicitly calls `performCommand(for: NSEvent)` — there's
  /// no automatic NSEvent → extension routing. Without this hook
  /// shortcuts like Bitwarden's Cmd+Shift+L (autofill) ring the
  /// system bell and never reach the bg listener.
  ///
  /// Runs *before* the e05 Action registry handles the same
  /// keystroke so extension shortcuts win over our menu items —
  /// matches the precedence Chrome and Safari use for
  /// extension-declared commands.
  private func installExtensionCommandMonitor() {
    if let existing = extensionCommandMonitor {
      NSEvent.removeMonitor(existing)
      extensionCommandMonitor = nil
    }
    extensionCommandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if ExtensionController.shared.performExtensionCommand(for: event) {
        return nil
      }
      return event
    }
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
      actions.indices.contains(menuItem.tag)
    else {
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
