import AppKit
import E05Lib
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "App")

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

  /// `PreferencesStore` subscription that drives `NSApp.appearance`.
  /// Held for the app's lifetime so Theme picker writes flow back
  /// here without a relaunch.
  private var themeListenerToken: UUID?

  /// `PreferencesStore` subscription that rebuilds the main menu so
  /// a Shortcuts edit takes effect without a relaunch. The palette
  /// re-queries `actions()` on every show so it picks up the new
  /// chord automatically; only NSMenu caches its key equivalents.
  private var shortcutListenerToken: UUID?

  /// Snapshot of the override dict used to gate menu rebuilds. The
  /// listener fan-out fires for every preferences write (theme,
  /// accent, etc.), and NSMenu construction touches the whole pane
  /// VC graph; rebuilding only when the override dict actually
  /// changed keeps the unrelated tabs free.
  private var lastShortcutOverrides: [String: ShortcutBinding]?

  /// `PreferencesStore` subscription that walks every workspace,
  /// column, and resize handle to push the new ``PaneGapPreset``
  /// constants through the live layout. Held for the app lifetime
  /// so the Appearance picker takes effect without a relaunch.
  private var paneGapListenerToken: UUID?

  /// Snapshot of the gap identifier used to gate the layout walk.
  /// The listener fans out for every preferences write; comparing
  /// against the last applied value skips the walk when an unrelated
  /// field flipped.
  private var lastPaneGap: String?

  /// `PreferencesStore` subscription that reloads the worklane and
  /// re-applies the focused-pane border on every workspace whenever
  /// the accent palette flips. The accent reader is computed-on-read
  /// already; this listener is what triggers the repaint.
  private var accentPaletteListenerToken: UUID?
  private var lastAccentPalette: String?

  /// `PreferencesStore` subscription that re-applies the focused-pane
  /// border on every workspace whenever the pane border width flips.
  /// Same shape as the accent listener; kept separate so the
  /// snapshot diff gate fires for each field independently.
  private var paneBorderWidthListenerToken: UUID?
  private var lastPaneBorderWidth: String?

  /// Last effective appearance ``applyTheme`` saw, used to detect
  /// light ↔ dark transitions and drop the favicon memory cache.
  /// `prefers-color-scheme`-aware SVG favicons are cached as
  /// `NSImage` instances decoded under the appearance in effect at
  /// fetch time; a later flip without an eviction leaves a now-
  /// mismatched glyph (e.g. white on white in light theme) until
  /// the next cold reload.
  private var lastEffectiveAppearance: NSAppearance.Name?

  /// Background loop that runs the periodic adblocker filterlist
  /// refresh. Reads the interval from `PreferencesStore` each
  /// iteration; held so a Settings edit can cancel the previous
  /// run via the `adblockerScheduleListenerToken` listener before
  /// starting a fresh scheduler.
  private var adblockerScheduleTask: Task<Void, Never>?

  /// `PreferencesStore` subscription that reschedules
  /// ``adblockerScheduleTask`` whenever the user changes the
  /// auto-update interval, so a flip from Weekly to Daily (or off)
  /// takes effect immediately rather than after the previous sleep
  /// resolves.
  private var adblockerScheduleListenerToken: UUID?

  /// Last observed interval; the listener uses this to gate
  /// reschedules so unrelated preference writes (theme, accent,
  /// shortcuts, etc.) do not bounce the scheduler.
  private var lastAdblockerInterval: Int?

  /// KVO observer on `NSApp.effectiveAppearance`. The OS's
  /// Light / Dark auto-switch (e.g. sunset / sunrise schedule
  /// under "Auto" in System Settings) bypasses the
  /// `PreferencesStore` path because `theme` stays at `system`, so
  /// the panel-appearance cache flush wouldn't run. KVO catches the
  /// change and re-applies the theme so child panels follow the
  /// system swap.
  private var effectiveAppearanceObserver: NSKeyValueObservation?

  /// Re-entry guard for ``applyTheme``. Setting
  /// `NSApp.appearance` triggers another `effectiveAppearance`
  /// change, and the KVO observer would otherwise recurse into
  /// `applyTheme` indefinitely.
  private var isApplyingTheme = false

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
    startAdblockerAutoUpdateSchedule()
    lastAdblockerInterval = PreferencesStore.shared.preferences.adblockerAutoUpdateIntervalHours
    adblockerScheduleListenerToken = PreferencesStore.shared.addListener { [weak self] prefs in
      guard let self else { return }
      let next = prefs.adblockerAutoUpdateIntervalHours
      if next == self.lastAdblockerInterval { return }
      self.lastAdblockerInterval = next
      self.startAdblockerAutoUpdateSchedule()
    }

    // Drive `NSApp.appearance` from `ThemePreset` so the Appearance
    // tab's Theme picker (System / Light / Dark) reaches every NSView
    // through the standard inheritance chain. The listener fan-out
    // re-applies on every preferences write so a Theme change
    // propagates live; `nil` (system) is the explicit opt-out value
    // that defers to the OS Appearance preference.
    applyTheme()
    themeListenerToken = PreferencesStore.shared.addListener { [weak self] _ in
      self?.applyTheme()
    }
    effectiveAppearanceObserver = NSApp.observe(
      \.effectiveAppearance, options: [.new]
    ) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.applyTheme() }
    }

    lastShortcutOverrides = PreferencesStore.shared.preferences.keyboardShortcuts
    shortcutListenerToken = PreferencesStore.shared.addListener { [weak self] prefs in
      guard let self else { return }
      let next = prefs.keyboardShortcuts
      if next == self.lastShortcutOverrides { return }
      self.lastShortcutOverrides = next
      self.setupMenuKeyBindings()
    }

    lastPaneGap = PreferencesStore.shared.preferences.paneGap
    paneGapListenerToken = PreferencesStore.shared.addListener { [weak self] prefs in
      guard let self else { return }
      let next = prefs.paneGap
      if next == self.lastPaneGap { return }
      self.lastPaneGap = next
      self.paneContainer?.applyPaneGap()
    }

    lastAccentPalette = PreferencesStore.shared.preferences.accentPalette
    accentPaletteListenerToken = PreferencesStore.shared.addListener {
      [weak self] prefs in
      guard let self else { return }
      let next = prefs.accentPalette
      if next == self.lastAccentPalette { return }
      self.lastAccentPalette = next
      self.paneContainer?.applyAccentPalette()
    }

    lastPaneBorderWidth = PreferencesStore.shared.preferences.paneBorderWidth
    paneBorderWidthListenerToken = PreferencesStore.shared.addListener {
      [weak self] prefs in
      guard let self else { return }
      let next = prefs.paneBorderWidth
      if next == self.lastPaneBorderWidth { return }
      self.lastPaneBorderWidth = next
      self.paneContainer?.applyPaneBorderWidth()
    }

    let screen = NSScreen.main ?? NSScreen.screens.first
    let initialSize: NSSize = {
      if let visible = screen?.visibleFrame {
        return NSSize(width: visible.width * 0.85, height: visible.height * 0.80)
      }
      // Fallback for headless environments where NSScreen returns nil.
      return NSSize(width: 1440, height: 900)
    }()
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: initialSize),
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
    // Seed the Settings host so the Shortcuts tab can resolve
    // `actions()` even before the user invokes `open_settings` —
    // matters for tests that exercise Settings in isolation, and
    // keeps the wiring symmetric with the live launch path.
    SettingsWindowController.shared.paneContainer = container

    // Assigning `contentViewController` resets the window's content
    // size to the VC's `preferredContentSize` (zero), which the
    // window then clamps up to `contentMinSize`. Reapply the
    // requested size here so the clamp doesn't win.
    window.setContentSize(initialSize)

    // `setFrameAutosaveName(_:) -> Bool` reports name conflicts, not
    // "saved frame was applied", so read the autosave key from
    // `UserDefaults` directly to detect a saved frame before the
    // call applies it.
    let autosaveName = "e05.main-window.v3"
    let savedFrameKey = "NSWindow Frame \(autosaveName)"
    let hasSavedFrame = UserDefaults.standard.object(forKey: savedFrameKey) != nil
    window.setFrameAutosaveName(autosaveName)

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

    if !hasSavedFrame, let visible = screen?.visibleFrame {
      // Don't use `NSWindow.center()`: it places the top edge one-
      // third down from the screen top, which on a near-fullscreen
      // window clamps the bottom edge to the screen. Centre against
      // `visibleFrame` (menu bar / Dock already excluded) instead.
      let origin = NSPoint(
        x: visible.minX + (visible.width - initialSize.width) / 2,
        y: visible.minY + (visible.height - initialSize.height) / 2)
      window.setFrameOrigin(origin)
    }
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
  /// Apply the active theme preset to `NSApp.appearance` and every
  /// existing `NSWindow`. Called at launch and again on every
  /// preferences mutation so a Theme picker change reaches every
  /// NSView through the standard appearance-inheritance chain.
  ///
  /// Setting `NSApp.appearance` alone is not enough: child panels
  /// that host transient chrome (command palette, find bar, URL bar
  /// dropdown) capture their `appearance` at creation and don't
  /// re-read `NSApp.appearance` on later swaps. Pushing the value
  /// into every existing window kicks each panel's
  /// `effectiveAppearance` so the chrome inside also flips.
  ///
  /// `ThemePreset.system` maps to `nil`, the explicit opt-out value
  /// that defers to the OS Appearance preference.
  private func applyTheme() {
    guard !isApplyingTheme else { return }
    isApplyingTheme = true
    defer { isApplyingTheme = false }
    let preset = ThemePreset.resolve(
      PreferencesStore.shared.preferences.theme)
    let appearance = preset.appearance
    NSApp.appearance = appearance
    for window in NSApp.windows {
      window.appearance = appearance
    }
    // Tell libghostty which side of the light/dark axis the host is
    // on so a `theme = light:X,dark:Y` config swaps colors without a
    // restart. Reading `effectiveAppearance` (rather than `preset
    // .appearance`) lets `ThemePreset.system` resolve through the OS
    // preference, including auto-switch by schedule.
    //
    // Existing surfaces won't repaint from the app-level update
    // alone: every surface carries its own conditional state seeded
    // at creation. The container fan-out walks each terminal surface
    // and pushes the scheme so the surface re-derives its theme
    // branch — matching how the official ghostty macOS app pairs
    // `ghostty_app_set_color_scheme` with a per-surface call.
    let scheme = GhosttyColorScheme(NSApp.effectiveAppearance)
    ghosttyApp.setColorScheme(scheme)
    paneContainer?.applyTerminalColorScheme(scheme)

    // Evict in-memory favicons on actual light ↔ dark transitions so
    // theme-aware SVGs re-decode under the new appearance on the
    // next sidebar / URL bar draw. The on-disk raw bytes are
    // appearance-neutral, so disk is left intact. The first apply
    // only seeds `lastEffectiveAppearance` so cold launch is a no-op.
    // A spurious KVO bounce across the same appearance pair would
    // be filtered by the equality check; one that briefly reports a
    // different `bestMatch` value can fire a redundant drop, which
    // costs a re-decode on the next draw — acceptable since the
    // disk side carries over.
    let currentAppearance = NSApp.effectiveAppearance.bestMatch(
      from: [.aqua, .darkAqua])
    if let last = lastEffectiveAppearance, last != currentAppearance {
      FaviconCache.shared.dropMemoryCache()
    }
    lastEffectiveAppearance = currentAppearance
  }

  /// Periodic refresh loop for the adblocker filterlists. Reads the
  /// interval from `PreferencesStore` at the top of each iteration
  /// (and via the listener that calls back here on Settings edits).
  /// `nil` interval falls back to the engine's default (weekly);
  /// `0` (or negative) disables the loop until the next reschedule.
  /// The first iteration honours the existing
  /// `adblockerLastRefreshedAt` timestamp, so a hot restart inside
  /// the interval window does not double-fetch upstream.
  private func startAdblockerAutoUpdateSchedule() {
    adblockerScheduleTask?.cancel()
    adblockerScheduleTask = Task { @MainActor [weak self] in
      while let self, !Task.isCancelled {
        let prefs = PreferencesStore.shared.preferences
        let configured = prefs.adblockerAutoUpdateIntervalHours
          ?? AdBlocker.defaultAutoUpdateIntervalHours
        guard configured > 0 else { return }
        let interval = TimeInterval(configured) * 3600
        let last = prefs.adblockerLastRefreshedAt ?? .distantPast
        let elapsed = Date().timeIntervalSince(last)
        let delay = max(0, interval - elapsed)
        if delay > 0 {
          let ns = UInt64(delay * 1_000_000_000)
          try? await Task.sleep(nanoseconds: ns)
          if Task.isCancelled { return }
        }
        logger.info("[adblocker/schedule] auto-update fired")
        await AdBlocker.shared.refreshFilterlists()
      }
    }
  }

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
    // Every op needs the pane container, so the readiness check lives
    // here rather than being repeated per-case.
    guard let container = paneContainer else {
      return ControlSocket.Response(ok: false, error: "host not ready")
    }
    switch request {
    case .open(let urlString):
      guard let url = URL(string: urlString) else {
        return ControlSocket.Response(ok: false, error: "invalid 'url'")
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
    case .action(let id):
      guard container.dispatchAction(id: id) else {
        return ControlSocket.Response(ok: false, error: "unknown action: \(id)")
      }
      return ControlSocket.Response(ok: true)
    case .switchWorkspace(let index):
      // `switchWorkspace(to:)` no-ops on out-of-range indices already,
      // but reject up-front so the CLI sees a typed error rather than
      // an apparent success that did nothing.
      let workspaceCount = container.workspaces.count
      guard index >= 0 && index < workspaceCount else {
        return ControlSocket.Response(
          ok: false, error: "index \(index) out of range (have \(workspaceCount) workspaces)"
        )
      }
      container.switchWorkspace(to: index)
      return ControlSocket.Response(ok: true)
    case .notify(let message):
      // Empty string is a value-validation failure (JSON shape valid,
      // host rejects) so it lives here rather than in `Request.init`.
      guard !message.isEmpty else {
        return ControlSocket.Response(ok: false, error: "empty 'message'")
      }
      container.showToast(message)
      return ControlSocket.Response(ok: true)
    case .invalid(let message):
      return ControlSocket.Response(ok: false, error: message)
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

    self.actions = paneContainer?.actions() ?? []

    // App menu (required for ⌘+Q). `Settings…` lives here for HIG
    // parity — every native macOS app routes ⌘, through the
    // Application menu — and is sourced from the action registry by
    // id so the palette / IPC dispatch and the menu share one
    // handler. `Quit` stays a framework selector since
    // `NSApplication.terminate` is not a pane op.
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    if let settingsIndex = actions.firstIndex(where: { $0.id == "open_settings" }) {
      let action = actions[settingsIndex]
      let item = NSMenuItem(
        title: action.title,
        action: #selector(performAction(_:)),
        keyEquivalent: action.keyEquivalent ?? ""
      )
      item.keyEquivalentModifierMask = action.modifierMask
      item.tag = settingsIndex
      appMenu.addItem(item)
      appMenu.addItem(.separator())
    }
    appMenu.addItem(
      withTitle: "Quit e05",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // Pane menu — built from the Action registry. The `open_settings`
    // entry is rendered in the App menu above; skipping it here keeps
    // ⌘, off the Pane menu list while the underlying action stays
    // discoverable through the palette and IPC.
    let paneMenuItem = NSMenuItem()
    let paneMenu = NSMenu(title: "Pane")

    for (index, action) in actions.enumerated() {
      if action.id == "open_settings" { continue }
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
