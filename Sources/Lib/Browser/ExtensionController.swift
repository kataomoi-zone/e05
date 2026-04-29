import AppKit
import WebKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "Extensions")

/// Owns the single shared `WKWebExtensionController` used by every browser
/// pane. The controller must be attached to a `WKWebViewConfiguration`
/// before the `WKWebView` is initialized, so `BrowserPaneView` pulls
/// `shared.controller` from this singleton when it constructs its config.
///
/// Extensions live on disk as unpacked directories or ZIP archives under
/// `~/.config/e05/extensions/`. Each immediate child is interpreted as one
/// extension's resource base URL. The root directory is created lazily at
/// first scan; the user is responsible for placing extensions there.
@MainActor
public final class ExtensionController {
  public static let shared = ExtensionController()

  public let controller: WKWebExtensionController

  private let delegateProxy: DelegateProxy

  /// Activated extensions, ordered by load completion. The sidebar
  /// extensions list reads from this array to render the per-extension
  /// row; cells should treat the snapshot as opaque and re-fetch via
  /// `loadedExtensions` after every `didChangeNotification`.
  public private(set) var loadedExtensions: [LoadedExtension] = []

  /// Posted on the main queue whenever `loadedExtensions` is mutated
  /// (a successful load, an enable/disable toggle, or a future
  /// removal). Listener views subscribe via
  /// `NotificationCenter.addObserver(forName:...)` and re-fetch the
  /// snapshot from the controller on each fire — mirrors the
  /// `FaviconCache.didChangeNotification` pattern.
  public static let didChangeNotification = Notification.Name(
    "com.kawarimidoll.e05.ExtensionController.didChange"
  )

  /// Per-extension `WKWebExtensionContext` cache keyed by source-URL
  /// filename. Built once during `load(at:)` so a toggle from the
  /// sidebar can call `controller.load` / `controller.unload` without
  /// re-reading the manifest. The keys mirror `disabledFilenames` so
  /// the JSON state file stays portable across machines (the parent
  /// directory of `~/.config/e05/extensions/` is the user-controlled
  /// part; only the directory or ZIP basename is persisted).
  private var contextsByFilename: [String: WKWebExtensionContext] = [:]

  /// Set of source-URL filenames the user has explicitly disabled.
  /// Persisted as JSON at `extensionsStateFileURL`. Never includes
  /// filenames that aren't currently present on disk — the launch-time
  /// scan only writes back known entries, so a user pruning the
  /// extensions directory by hand doesn't accumulate stale entries.
  private var disabledFilenames: Set<String> = []

  /// One Task per active context, watching the context's
  /// `errorsDidUpdateNotification` stream. Tracked here so a toggle
  /// can cancel the old subscription before installing a new one — an
  /// untracked spawn would leave the previous Task running after
  /// `controller.unload` and a re-enable would stack a second Task on
  /// the same context, doubling every error log entry.
  private var errorsTasksByFilename: [String: Task<Void, Never>] = [:]

  private init() {
    self.controller = WKWebExtensionController(configuration: .default())
    self.delegateProxy = DelegateProxy()
    self.controller.delegate = delegateProxy
  }

  /// Root directory scanned at launch. Each immediate child (either an
  /// unpacked directory or a ZIP archive) is treated as an extension.
  public static var extensionsRoot: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/e05/extensions", isDirectory: true)
  }

  /// Persistent enable/disable state for installed extensions. Stored
  /// alongside the extensions root rather than inside it so a user
  /// who copies an extension directory between machines doesn't drag
  /// the state with it (the file's location matches the convention of
  /// the other top-level stores under `~/.config/e05/`).
  private static var extensionsStateFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config/e05/extensions-state.json", isDirectory: false)
  }

  /// On-disk shape of the state file. Kept as a dedicated nested
  /// `Codable` type so additions (e.g. per-extension permission
  /// overrides, last-update timestamps) can be appended later without
  /// breaking existing files — Codable synthesis tolerates unknown
  /// keys when decoding via the default initializer.
  private struct PersistedState: Codable {
    var disabledFilenames: [String] = []
  }

  /// Domain shared by every NSError thrown from this controller.
  /// `WKWebExtensionErrorDomain` covers WebKit's own load failures;
  /// our own validation errors (collision, missing source) live here.
  static let errorDomain = "com.kawarimidoll.e05.Extensions"

  /// Numeric code space for our NSErrors. Centralised so two callers
  /// can't reach for the same `code: 1` literal independently.
  private enum ErrorCode: Int {
    case alreadyInstalled = 1
    case notLoaded = 2
  }

  /// Scan `extensionsRoot` and load every child as an extension. Creates
  /// the root directory if missing to match the other persistence stores
  /// under `~/.config/e05/`; an empty directory simply produces no loads.
  public func loadAll() async {
    loadPersistedState()

    let root = Self.extensionsRoot
    let fm = FileManager.default

    do {
      try fm.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
      logger.error(
        """
        Failed to create extensions root at \
        \(root.path, privacy: .private(mask: .hash)): \
        \(String(describing: error), privacy: .public)
        """
      )
      return
    }

    let entries: [URL]
    do {
      entries = try fm.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    } catch {
      logger.error(
        "Failed to enumerate extensions root: \(String(describing: error), privacy: .public)"
      )
      return
    }

    for entry in entries {
      var entryIsDir: ObjCBool = false
      let exists = fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir)
      guard exists else { continue }
      let isZip = entry.pathExtension.lowercased() == "zip"
      guard entryIsDir.boolValue || isZip else { continue }
      // Tolerate a single bad extension at scan time — log and move
      // on. `addExtension` uses the throwing form for direct user
      // feedback, but here a startup-time scan must not abort just
      // because one disk entry has a malformed manifest.
      do {
        try await load(at: entry)
      } catch {
        logger.error(
          """
          Failed to load extension at \
          \(entry.path, privacy: .private(mask: .hash)): \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }

    // Re-write the state file restricted to filenames currently on
    // disk so removed extensions stop accumulating in the disabled
    // set. Unknown filenames still resolve to "enabled" on the next
    // launch, but trimming on every scan keeps the file small and
    // surfaces the live convention to anyone hand-editing it.
    let presentFilenames = Set(contextsByFilename.keys)
    let stale = disabledFilenames.subtracting(presentFilenames)
    if !stale.isEmpty {
      disabledFilenames.formIntersection(presentFilenames)
      savePersistedState()
    }
  }

  private func load(at url: URL) async throws {
    let ext = try await WKWebExtension(resourceBaseURL: url)
    let name = ext.displayName ?? url.lastPathComponent
    let mv = String(format: "%g", ext.manifestVersion)

    logger.info(
      """
      Loaded manifest '\(name, privacy: .public)' \
      v\(ext.version ?? "(unknown)", privacy: .public) MV\(mv, privacy: .public) \
      from \(url.lastPathComponent, privacy: .public) \
      caps[bg=\(ext.hasBackgroundContent), \
      persistBg=\(ext.hasPersistentBackgroundContent), \
      inject=\(ext.hasInjectedContent), \
      cmr=\(ext.hasContentModificationRules), \
      opts=\(ext.hasOptionsPage), \
      cmds=\(ext.hasCommands)]
      """
    )

    // Surface any parse-time errors immediately. For MV3 extensions
    // that expect Chrome-specific APIs (offscreen, userScripts, ...),
    // the parser may report non-fatal warnings here.
    for (i, err) in ext.errors.enumerated() {
      let ns = err as NSError
      logger.error(
        """
        Parse err[\(i)] for '\(name, privacy: .public)': \
        domain=\(ns.domain, privacy: .public) code=\(ns.code) \
        desc=\(ns.localizedDescription, privacy: .public)
        """
      )
    }

    let ctx = WKWebExtensionContext(for: ext)

    // Pre-grant every requested permission and host pattern so
    // content-blocking paths run end-to-end without surfacing a
    // prompt. Placing an extension under ~/.config/e05/extensions/
    // is treated as explicit user trust; a richer permission flow
    // ships with the extensions sidebar UI.
    let permNames = ext.requestedPermissions.map(\.rawValue).sorted()
    for perm in ext.requestedPermissions {
      ctx.setPermissionStatus(.grantedExplicitly, for: perm)
    }
    let patternStrings = ext.requestedPermissionMatchPatterns
      .map(\.string)
      .sorted()
    for pattern in ext.requestedPermissionMatchPatterns {
      ctx.setPermissionStatus(.grantedExplicitly, for: pattern)
    }
    logger.info(
      """
      Pre-granted \(permNames.count) perms \
      [\(permNames.joined(separator: ","), privacy: .public)] + \
      \(patternStrings.count) host patterns \
      [\(patternStrings.joined(separator: ","), privacy: .public)] \
      for '\(name, privacy: .public)'
      """
    )

    let filename = url.lastPathComponent
    contextsByFilename[filename] = ctx
    let isEnabled = !disabledFilenames.contains(filename)

    if isEnabled {
      try controller.load(ctx)

      let currentPermNames = ctx.currentPermissions.map(\.rawValue).sorted()
      logger.info(
        """
        Activated '\(name, privacy: .public)' \
        ctx[inject=\(ctx.hasInjectedContent), \
        cmr=\(ctx.hasContentModificationRules), \
        allURLs=\(ctx.hasAccessToAllURLs), \
        currentPerms=[\(currentPermNames.joined(separator: ","), privacy: .public)]]
        """
      )

      // Dump the error array immediately post-load — declarativeNetRequest
      // ruleset installation, background script boot, and any Chrome API
      // feature gaps will surface here within a few hundred milliseconds.
      Self.logErrors(ctx: ctx, source: "post-load")

      subscribeToErrors(ctx: ctx, name: name, key: filename)
      scheduleCapabilityRecheck(ctx: ctx, name: name)
    } else {
      logger.info(
        "Skipping controller.load for user-disabled '\(name, privacy: .public)'"
      )
    }

    let entry = LoadedExtension(
      sourceURL: url,
      displayName: name,
      version: ext.version,
      manifestVersion: ext.manifestVersion,
      icon: Self.bestIcon(for: ext),
      isEnabled: isEnabled
    )
    loadedExtensions.append(entry)
    // Stable display order across launches: filesystem enumeration
    // order is not guaranteed and async-load completion order would
    // shuffle the list further if loads ever run in parallel.
    loadedExtensions.sort {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Re-log extension capability flags a few seconds after load. The
  /// initial activation log is captured microseconds after `controller.load`,
  /// which is too early for async declarativeNetRequest ruleset install or
  /// service-worker-driven dynamic content script registration to complete.
  /// When the deferred context state contradicts what the manifest
  /// advertises, a warning is emitted — this is the earliest surface for
  /// silent WebKit feature gaps (e.g. `scripting.registerContentScripts`
  /// calls that succeed on the JS side but never reach the loader).
  private func scheduleCapabilityRecheck(ctx: WKWebExtensionContext, name: String) {
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      let ext = ctx.webExtension
      logger.info(
        """
        [+3s recheck] '\(name, privacy: .public)' \
        ctx[inject=\(ctx.hasInjectedContent), \
        cmr=\(ctx.hasContentModificationRules), \
        allURLs=\(ctx.hasAccessToAllURLs)]
        """
      )
      if ext.hasInjectedContent, !ctx.hasInjectedContent {
        logger.warning(
          """
          Extension '\(name, privacy: .public)' advertises injected content \
          but the context reports inject=false after 3s — content scripts \
          are not registered. Likely a WebKit scripting-API gap.
          """
        )
      }
      if ext.hasContentModificationRules, !ctx.hasContentModificationRules {
        logger.warning(
          """
          Extension '\(name, privacy: .public)' advertises content modification \
          rules but the context reports cmr=false after 3s — declarativeNetRequest \
          rulesets did not install.
          """
        )
      }
      Self.logErrors(ctx: ctx, source: "+3s recheck")
    }
  }

  private func subscribeToErrors(ctx: WKWebExtensionContext, name: String, key: String) {
    // Cancel the previous subscription for this context before
    // installing a new one. Without this, an enable/disable cycle
    // would leak the original Task — the AsyncSequence keeps the
    // for-await alive for the lifetime of `ctx`, so it would never
    // self-terminate after `controller.unload`.
    errorsTasksByFilename[key]?.cancel()

    // AsyncSequence form keeps both producer and consumer inside the
    // MainActor isolation domain, sidestepping the Sendable barrier
    // that the block-based `addObserver(forName:object:queue:using:)`
    // trips in Swift 6 (the Notification argument is task-isolated and
    // cannot be handed to a MainActor closure safely).
    let task = Task { @MainActor in
      let stream = NotificationCenter.default.notifications(
        named: WKWebExtensionContext.errorsDidUpdateNotification,
        object: ctx
      )
      for await _ in stream {
        Self.logErrors(ctx: ctx, source: "errorsDidUpdate")
      }
    }
    errorsTasksByFilename[key] = task
    logger.debug("Subscribed to errorsDidUpdate for '\(name, privacy: .public)'")
  }

  /// Resolve the best display icon for an extension. Prefers a 32pt
  /// action icon (toolbar / popup affordance) and falls back to the
  /// manifest icon at the same size, so both action-bearing extensions
  /// (uBO Lite, Bitwarden) and content-only extensions (declarative
  /// rule packs) render with a meaningful glyph in the sidebar list.
  /// Returns nil when neither is available; the cell paints a generic
  /// `puzzlepiece.extension` placeholder in that case.
  private static func bestIcon(for ext: WKWebExtension) -> NSImage? {
    let target = NSSize(width: 32, height: 32)
    if let actionIcon = ext.actionIcon(for: target) {
      return actionIcon
    }
    return ext.icon(for: target)
  }

  /// Snapshot of the extension's runtime errors at this instant.
  /// Returns an empty array when the source isn't loaded. Calls
  /// through to `WKWebExtensionContext.errors`, which collects parse-
  /// time issues, declarativeNetRequest installation failures, and
  /// Chrome-API gaps as they accumulate — useful surface for a
  /// `View Errors` menu entry.
  public func errors(for sourceURL: URL) -> [NSError] {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else { return [] }
    return ctx.errors as [NSError]
  }

  /// Re-parse and reactivate the extension. Equivalent to a remove +
  /// re-add round-trip but **preserves** the user's enable/disable
  /// state and the source's on-disk filename. Useful after editing a
  /// manifest or content script in place; the new context picks up
  /// the change without a full app relaunch.
  ///
  /// On failure (broken manifest, unsupported manifest version, etc.)
  /// the previously loaded context is re-installed so the sidebar row
  /// stays exactly as it was before the attempt. The user can then
  /// fix the source on disk and try again, or remove the extension
  /// outright. The caller presents the error in an `NSAlert`.
  public func reloadExtension(for sourceURL: URL) async throws {
    let filename = sourceURL.lastPathComponent
    guard let oldCtx = contextsByFilename[filename] else {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.notLoaded.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Cannot reload — '\(filename)' is not currently loaded."
        ]
      )
    }
    let displayName = oldCtx.webExtension.displayName ?? filename
    let wasEnabled = !disabledFilenames.contains(filename)

    errorsTasksByFilename[filename]?.cancel()
    errorsTasksByFilename.removeValue(forKey: filename)
    if wasEnabled {
      // Mirrors the `removeExtension` unload gate: skipping unload for
      // disabled rows because `load(at:)` never called `controller.load`
      // for them in the first place, so calling unload here would throw.
      do {
        try controller.unload(oldCtx)
      } catch {
        logger.error(
          """
          controller.unload during reload failed for \
          '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }
    contextsByFilename.removeValue(forKey: filename)
    loadedExtensions.removeAll { $0.sourceURL == sourceURL }

    do {
      // `load(at:)` reads `disabledFilenames` to decide whether to
      // re-`controller.load`, so the user-toggled state survives the
      // round-trip without explicit handling here.
      try await load(at: sourceURL)
      logger.info("Reloaded '\(displayName, privacy: .public)'")
    } catch {
      // Rollback: re-install the previously loaded context so the
      // sidebar row reverts to what was visible before the reload
      // attempt. The on-disk source still holds the broken manifest;
      // restoring controller state lets the user keep using the
      // working version while they fix the source.
      restoreAfterFailedReload(
        oldCtx: oldCtx,
        sourceURL: sourceURL,
        filename: filename,
        wasEnabled: wasEnabled,
        displayName: displayName
      )
      throw error
    }
  }

  /// Re-install the previous context after a failed `reloadExtension`.
  /// The old `WKWebExtension` is still valid (we never touched the
  /// on-disk source during the reload attempt), so the snapshot can
  /// be rebuilt from it and the controller re-loaded with the same
  /// instance. Errors during rollback are logged but never re-thrown:
  /// the caller is already in the middle of throwing the original
  /// reload error, and a rollback failure is tertiary information at
  /// best.
  private func restoreAfterFailedReload(
    oldCtx: WKWebExtensionContext,
    sourceURL: URL,
    filename: String,
    wasEnabled: Bool,
    displayName: String
  ) {
    contextsByFilename[filename] = oldCtx
    if wasEnabled {
      do {
        try controller.load(oldCtx)
        subscribeToErrors(ctx: oldCtx, name: displayName, key: filename)
        scheduleCapabilityRecheck(ctx: oldCtx, name: displayName)
      } catch {
        // Double failure — both the new manifest load and the rollback
        // controller.load have throw'd. The cache and snapshot still
        // get rebuilt below so the row stays visible, but the error
        // subscription is not re-armed; runtime errors from the old
        // context will not surface in `View Errors` until the next
        // successful reload (or app relaunch).
        logger.error(
          """
          Rollback controller.load failed for \
          '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }
    let oldExt = oldCtx.webExtension
    let entry = LoadedExtension(
      sourceURL: sourceURL,
      displayName: displayName,
      version: oldExt.version,
      manifestVersion: oldExt.manifestVersion,
      icon: Self.bestIcon(for: oldExt),
      isEnabled: wasEnabled
    )
    loadedExtensions.append(entry)
    loadedExtensions.sort {
      $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Copy an unpacked extension folder (or ZIP archive) into
  /// `extensionsRoot` and load it, so the new entry appears in the
  /// sidebar alongside the existing extensions. Throws if the
  /// destination already exists — replacing in place would silently
  /// drop user-toggled state and re-arm permission grants for what
  /// could be a different version. Throws and rolls back the copy if
  /// the load itself fails (malformed manifest, unsupported manifest
  /// version, etc.) so a bad install doesn't leave a dead directory
  /// that re-fails on every launch. The caller (sidebar UI) presents
  /// the error in an `NSAlert`.
  public func addExtension(from sourceURL: URL) async throws {
    let fm = FileManager.default
    try fm.createDirectory(at: Self.extensionsRoot, withIntermediateDirectories: true)
    let dst = Self.extensionsRoot.appendingPathComponent(sourceURL.lastPathComponent)
    if fm.fileExists(atPath: dst.path) {
      throw NSError(
        domain: Self.errorDomain,
        code: ErrorCode.alreadyInstalled.rawValue,
        userInfo: [
          NSLocalizedDescriptionKey:
            "An extension named '\(sourceURL.lastPathComponent)' is already installed. "
            + "Remove the existing copy first if you want to replace it."
        ]
      )
    }
    try fm.copyItem(at: sourceURL, to: dst)
    do {
      try await load(at: dst)
    } catch {
      // The copy succeeded but the manifest didn't parse / register.
      // Removing the destination keeps the next launch's scan from
      // re-failing on the same input and matches the user's
      // expectation that a failed install leaves no trace.
      try? fm.removeItem(at: dst)
      throw error
    }
  }

  /// Move an extension to the Trash and tear down every cache entry
  /// the controller keeps for it. The Trash is the right destination
  /// (rather than `removeItem`) so the user can put the extension
  /// back if they removed the wrong one — same Finder-style policy
  /// the e05 finder pane already uses for its `Move to Trash` action.
  /// Cleanup proceeds even if the trash step fails: the controller
  /// caches are still cleared, and on next launch the scan will pick
  /// up the still-on-disk source as a fresh entry. That re-loading
  /// behaviour is documented (not a bug); a Trash failure leaves the
  /// extension visibly back in the list after a restart.
  public func removeExtension(for sourceURL: URL) {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else {
      logger.error(
        "removeExtension for unknown source '\(filename, privacy: .public)' — ignored"
      )
      return
    }
    let displayName = ctx.webExtension.displayName ?? filename

    errorsTasksByFilename[filename]?.cancel()
    errorsTasksByFilename.removeValue(forKey: filename)

    // Skip `controller.unload` for entries that were never loaded —
    // `load(at:)` skips `controller.load` for any filename in
    // `disabledFilenames`, so calling unload here would always throw
    // for disabled rows. The throw itself is harmless but the
    // resulting log line reads like a real bug.
    if !disabledFilenames.contains(filename) {
      do {
        try controller.unload(ctx)
      } catch {
        logger.error(
          """
          controller.unload during remove failed for \
          '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }

    do {
      try FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
      logger.info("Trashed '\(displayName, privacy: .public)'")
    } catch {
      logger.error(
        """
        trashItem failed for '\(sourceURL.lastPathComponent, privacy: .public)': \
        \(String(describing: error), privacy: .public). \
        Controller caches cleared anyway; the source on disk will \
        re-appear after the next launch's scan.
        """
      )
    }

    contextsByFilename.removeValue(forKey: filename)
    disabledFilenames.remove(filename)
    loadedExtensions.removeAll { $0.sourceURL == sourceURL }
    savePersistedState()
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  /// Toggle the runtime activation of `sourceURL`'s extension and
  /// persist the new state. Idempotent on the requested side: calling
  /// with `true` for an already-enabled extension is a cheap no-op.
  /// Failures from `controller.load` / `controller.unload` are logged
  /// but the persisted state is still updated — the alternative
  /// (rolling back the user's intent because WebKit had a transient
  /// problem) makes the toggle feel unreliable in practice.
  public func setEnabled(_ enabled: Bool, for sourceURL: URL) {
    let filename = sourceURL.lastPathComponent
    guard let ctx = contextsByFilename[filename] else {
      logger.error(
        "setEnabled(\(enabled)) for unknown source '\(filename, privacy: .public)' — ignored"
      )
      return
    }
    let wasDisabled = disabledFilenames.contains(filename)
    guard enabled == wasDisabled else { return }

    let displayName = ctx.webExtension.displayName ?? filename
    if enabled {
      disabledFilenames.remove(filename)
      do {
        try controller.load(ctx)
        logger.info("Enabled '\(displayName, privacy: .public)'")
        // Re-arm the diagnostics channels we wired during the initial
        // load so a re-enabled extension produces the same telemetry
        // as a freshly installed one. Kept inside the try so a failed
        // load doesn't leave a subscriber attached to an inactive
        // context.
        subscribeToErrors(ctx: ctx, name: displayName, key: filename)
        scheduleCapabilityRecheck(ctx: ctx, name: displayName)
      } catch {
        logger.error(
          """
          controller.load failed for '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    } else {
      disabledFilenames.insert(filename)
      // Tear down the diagnostics subscription so the AsyncSequence
      // for-await self-terminates and the Task can be released.
      errorsTasksByFilename[filename]?.cancel()
      errorsTasksByFilename.removeValue(forKey: filename)
      do {
        try controller.unload(ctx)
        logger.info("Disabled '\(displayName, privacy: .public)'")
      } catch {
        logger.error(
          """
          controller.unload failed for '\(displayName, privacy: .public)': \
          \(String(describing: error), privacy: .public)
          """
        )
      }
    }

    // Mirror the new flag into the snapshot array so listeners that
    // re-read `loadedExtensions` after the post observe the change
    // without an extra round-trip through the controller.
    if let i = loadedExtensions.firstIndex(where: { $0.sourceURL == sourceURL }) {
      loadedExtensions[i].isEnabled = enabled
    }
    savePersistedState()
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }

  private func loadPersistedState() {
    let url = Self.extensionsStateFileURL
    guard let data = try? Data(contentsOf: url) else {
      // A missing file is the first-run convention, not an error —
      // every extension defaults to enabled until the user toggles
      // one off.
      return
    }
    do {
      let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
      disabledFilenames = Set(decoded.disabledFilenames)
    } catch {
      logger.error(
        """
        Failed to decode extensions-state.json: \
        \(String(describing: error), privacy: .public). \
        Falling back to all-enabled defaults.
        """
      )
    }
  }

  private func savePersistedState() {
    let url = Self.extensionsStateFileURL
    let payload = PersistedState(disabledFilenames: disabledFilenames.sorted())
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(payload)
      try data.write(to: url, options: [.atomic])
    } catch {
      logger.error(
        """
        Failed to write extensions-state.json at \
        \(url.path, privacy: .private(mask: .hash)): \
        \(String(describing: error), privacy: .public)
        """
      )
    }
  }

  private static func logErrors(ctx: WKWebExtensionContext, source: String) {
    let errs = ctx.errors
    let name = ctx.webExtension.displayName ?? "(unknown)"
    if errs.isEmpty {
      logger.info(
        "[\(source, privacy: .public)] no runtime errors for '\(name, privacy: .public)'"
      )
      return
    }
    for (i, err) in errs.enumerated() {
      let ns = err as NSError
      logger.error(
        """
        [\(source, privacy: .public)] err[\(i)] for '\(name, privacy: .public)': \
        domain=\(ns.domain, privacy: .public) code=\(ns.code) \
        desc=\(ns.localizedDescription, privacy: .public) \
        userInfo=\(String(describing: ns.userInfo))
        """
      )
    }
  }
}

/// Snapshot of one activated extension surfaced to the sidebar list.
/// Captured at load time so repeated reads (cell render, listener
/// fan-out) don't re-touch the underlying `WKWebExtensionContext`.
/// `NSImage` is not `Sendable`, so the type is `MainActor`-confined —
/// every accessor touches it from the main queue. Stable identity for
/// per-row routing comes from `sourceURL`: the directory or ZIP path
/// under `~/.config/e05/extensions/` is unique per extension.
@MainActor
public struct LoadedExtension {
  public let sourceURL: URL
  public let displayName: String
  public let version: String?
  public let manifestVersion: Double
  public let icon: NSImage?
  /// Reflects whether `controller.load` is currently active for this
  /// entry. Mutable so the controller's `setEnabled` can flip the
  /// snapshot in place; external callers should treat the value as
  /// read-only and route changes through `ExtensionController`.
  public internal(set) var isEnabled: Bool
}

/// Delegate wrapper kept as a private class so the controller retains it via
/// its weak `delegate` pointer (a struct would be released immediately).
@MainActor
private final class DelegateProxy: NSObject, WKWebExtensionControllerDelegate {
  // Window / tab protocol adoption on WorkspaceModel / PaneModel is a
  // follow-up change. Returning empty / nil keeps declarativeNetRequest
  // blockers working at the network layer without a tab model.
  func webExtensionController(
    _: WKWebExtensionController,
    openWindowsFor _: WKWebExtensionContext
  ) -> [any WKWebExtensionWindow] {
    []
  }

  func webExtensionController(
    _: WKWebExtensionController,
    focusedWindowFor _: WKWebExtensionContext
  ) -> (any WKWebExtensionWindow)? {
    nil
  }

  // Three symmetric auto-grant paths — runtime-prompted permissions,
  // URL access, and match-pattern access. Leaving any of these
  // unimplemented maps to silent denial in WebKit, which is painful
  // to diagnose when an extension requests an optional host late.
  func webExtensionController(
    _: WKWebExtensionController,
    promptForPermissions permissions: Set<WKWebExtension.Permission>,
    in _: (any WKWebExtensionTab)?,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
  ) {
    let names = permissions.map(\.rawValue).sorted().joined(separator: ",")
    logger.info(
      """
      Auto-granting runtime-prompted permissions [\(names, privacy: .public)] for \
      '\(context.webExtension.displayName ?? "(unknown)", privacy: .public)'
      """
    )
    completionHandler(permissions, nil)
  }

  func webExtensionController(
    _: WKWebExtensionController,
    promptForPermissionToAccess urls: Set<URL>,
    in _: (any WKWebExtensionTab)?,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Set<URL>, Date?) -> Void
  ) {
    let urlStrings = urls.map(\.absoluteString).sorted().joined(separator: ",")
    logger.info(
      """
      Auto-granting runtime URL access [\(urlStrings, privacy: .public)] for \
      '\(context.webExtension.displayName ?? "(unknown)", privacy: .public)'
      """
    )
    completionHandler(urls, nil)
  }

  func webExtensionController(
    _: WKWebExtensionController,
    promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
    in _: (any WKWebExtensionTab)?,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
  ) {
    let patternStrings = patterns.map(\.string).sorted().joined(separator: ",")
    logger.info(
      """
      Auto-granting runtime match patterns [\(patternStrings, privacy: .public)] for \
      '\(context.webExtension.displayName ?? "(unknown)", privacy: .public)'
      """
    )
    completionHandler(patterns, nil)
  }

  // Completion is called with `nil` error so the extension treats the
  // request as handled; the popup itself is silently suppressed until
  // the toolbar surface lands. Returning an error would make well-behaved
  // extensions retry on every user gesture.
  func webExtensionController(
    _: WKWebExtensionController,
    presentActionPopup _: WKWebExtension.Action,
    for context: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    logger.info(
      """
      presentActionPopup requested for \
      '\(context.webExtension.displayName ?? "(unknown)", privacy: .public)' — \
      suppressed until the toolbar action surface lands
      """
    )
    completionHandler(nil)
  }
}
