import AppKit
import E05Lib
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "App")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  private var window: NSWindow?
  private let ghosttyApp = GhosttyApp()
  private var paneContainer: PaneContainerViewController?

  /// Strong reference for the WKWebsiteDataStore + UNUserNotificationCenter
  /// delegate. `WKWebsiteDataStore._delegate` is `weak`, so the delegate
  /// would be deallocated immediately if we let it go out of scope. Only
  /// `WKWebsiteDataStore.default()` is attached; private workspaces' own
  /// `nonPersistent()` data stores are intentionally not wired (private
  /// mode and persistent notifications don't mix).
  private var notificationDelivery: NotificationDeliveryDelegate?
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

  /// Unix-socket IPC listener. External `e05` CLI invocations land
  /// here; the handler closure runs on the main actor so it can touch
  /// `paneContainer` directly. Held strongly so the listener keeps
  /// running for the host process lifetime.
  private var controlSocket: ControlSocket?

  func applicationDidFinishLaunching(_: Notification) {
    // Prepend the bundled `Contents/Resources/bin` to PATH so every
    // ghostty surface inherits the e05-aware shims (the `open`
    // redirect that lands `open .` / `open https://...` as a pane on
    // the host). Skipped when the directory is absent so `swift run`
    // and other non-bundled launches keep stock PATH; the `contains`
    // gate makes the inject idempotent against future re-init paths.
    if let resourceURL = Bundle.main.resourceURL {
      let binDir = resourceURL.appendingPathComponent("bin").path
      if FileManager.default.fileExists(atPath: binDir) {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let alreadyInjected = current.split(separator: ":").contains(Substring(binDir))
        if !alreadyInjected {
          if setenv("PATH", "\(binDir):\(current)", 1) != 0 {
            logger.error("[app/path-inject] setenv PATH failed errno=\(errno)")
          }
        }
      }
    }

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

    // Attach the notification delivery delegate BEFORE loading any
    // extension — extensions can register service workers that fire
    // `self.registration.showNotification(...)` immediately on load,
    // and a missed delegate at that moment drops the first batch of
    // notifications until the data store is poked again. The order
    // mirrors `bindContainer` (must precede `loadAll`). `install`
    // returns `nil` (and logs) when the WebKit SPI is unavailable
    // on this macOS revision; we keep the property type uniform so
    // the rest of the code can treat the no-wire case as no-op.
    self.notificationDelivery = NotificationDeliveryDelegate.install(
      container: container
    )

    Task { await ExtensionController.shared.loadAll() }

    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    self.window = window

    setupMenuKeyBindings()
    installTabKeyMonitor()
    installExtensionCommandMonitor()
    installControlSocket()
  }

  /// Bring up the `~/Library/Application Support/<bid>/control.sock`
  /// listener. EADDRINUSE means a sibling e05 with the same bundle id
  /// is already running, so this process aborts before persisting any
  /// state — the single-window invariant is supposed to keep the
  /// listener unique, and a half-functional duplicate would silently
  /// route CLI clients to a phantom window. Other start failures are
  /// logged and tolerated — IPC is a convenience surface, not a
  /// launch prerequisite.
  private func installControlSocket() {
    let path = E05Paths.default.dataDir
      .appendingPathComponent("control.sock").path
    let socket = ControlSocket(socketPath: path) { [weak self] request in
      self?.handleControlRequest(request)
        ?? ControlSocket.Response(ok: false, error: "host not ready")
    }
    do {
      try socket.start()
      self.controlSocket = socket
    } catch let posix as POSIXError where posix.code == .EADDRINUSE {
      logger.error(
        "[app/ipc] another e05 instance owns \(path, privacy: .public); aborting startup"
      )
      // Skip `NSApp.terminate` so `applicationWillTerminate` does not
      // run — that path would call `paneContainer?.saveSession()` and
      // overwrite the live instance's session with this aborted
      // process's empty default state.
      Darwin.exit(75)  // EX_TEMPFAIL
    } catch {
      logger.error(
        "[app/ipc] control socket start failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func handleControlRequest(_ request: ControlSocket.Request) -> ControlSocket.Response {
    switch request.op {
    case "open":
      guard let urlString = request.url, let url = URL(string: urlString) else {
        return ControlSocket.Response(ok: false, error: "missing or invalid 'url'")
      }
      guard let container = paneContainer else {
        return ControlSocket.Response(ok: false, error: "paneContainer not yet attached")
      }
      let address: PaneAddress
      if url.isFileURL {
        address = PaneAddress.finder(path: url.path(percentEncoded: false))
      } else {
        address = PaneAddress(url)
      }
      container.addColumn(address: address)
      window?.makeKeyAndOrderFront(nil)
      NSApp.activate()
      return ControlSocket.Response(ok: true)
    case "action":
      guard let actionId = request.id else {
        return ControlSocket.Response(ok: false, error: "missing 'id'")
      }
      guard let container = paneContainer else {
        return ControlSocket.Response(ok: false, error: "paneContainer not yet attached")
      }
      guard container.dispatchAction(id: actionId) else {
        return ControlSocket.Response(ok: false, error: "unknown action: \(actionId)")
      }
      return ControlSocket.Response(ok: true)
    default:
      return ControlSocket.Response(ok: false, error: "unknown op: \(request.op)")
    }
  }

  /// Route `CFBundleURLTypes` activations into a new column,
  /// matching Safari / Chrome's "external URL → new tab" model.
  /// AppKit guarantees `paneContainer` is attached before this
  /// fires, but the nil guard remains for re-entrant test paths.
  /// Subsequent `addColumn` calls each move `focusedColumnIndex`
  /// to the inserted slot, so multi-URL invocations land in the
  /// same order the caller passed.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let container = paneContainer else {
      logger.error("[app/url] dropped \(urls.count) URL(s): paneContainer not yet attached")
      return
    }
    for url in urls {
      let address = PaneAddress(url)
      if address.kind == .unknown {
        logger.warning(
          "[app/url] opening unknown address as blank browser: \(url.absoluteString, privacy: .public)"
        )
      }
      container.addColumn(address: address)
    }
    window?.makeKeyAndOrderFront(nil)
    application.activate()
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
    controlSocket?.stop()
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
        event.keyCode == KeyCode.tab
      else { return event }
      let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      // Only handle plain ⌃⇥ / ⌃⇧⇥. Letting ⌘⇥ / ⌥⇥ through keeps
      // the OS-level app switcher and any future option-tab keymap
      // intact.
      guard mods == .control || mods == [.control, .shift] else { return event }
      guard let pc = self.paneContainer else { return event }
      // Don't hijack ⌃⇥ while text input owns first responder
      // (command palette field, URL bar, web form). NSTextField
      // delegates key handling to an NSTextView field editor, both
      // of which inherit from NSText.
      if let responder = pc.view.window?.firstResponder, responder is NSText {
        return event
      }
      // Also bail while the command palette is showing — its field
      // editor may not have first responder yet, and switching pane
      // out from under the palette leaves it stranded.
      if pc.commandPalette.isVisible {
        return event
      }
      let shifted = mods.contains(.shift)
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
    // Disable every e05 action while the main window has a sheet
    // attached. The modern `requestMediaCapturePermissionFor` hook
    // ships with WebKit's own modal hold so the parent window's key
    // dispatch is suspended for free, but the legacy
    // `_webView:requestGeolocationPermissionForOrigin:...` SPI does
    // not — without this guard a geolocation prompt sees ⌘W slip
    // through to `removeCurrentPane`, the pane vanishes mid-sheet,
    // and AppKit leaves the modal dim layer orphaned on the host
    // window. Stock AppKit actions (Edit > Cut/Copy/Paste, Window
    // menu, …) bypass this validator entirely and stay reachable.
    if NSApp.mainWindow?.attachedSheet != nil {
      return false
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
