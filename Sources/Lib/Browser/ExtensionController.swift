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

  /// Scan `extensionsRoot` and load every child as an extension. Creates
  /// the root directory if missing to match the other persistence stores
  /// under `~/.config/e05/`; an empty directory simply produces no loads.
  public func loadAll() async {
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
      await load(at: entry)
    }
  }

  private func load(at url: URL) async {
    do {
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

      subscribeToErrors(ctx: ctx, name: name)
      scheduleCapabilityRecheck(ctx: ctx, name: name)
    } catch {
      logger.error(
        """
        Failed to load extension at \
        \(url.path, privacy: .private(mask: .hash)): \
        \(String(describing: error), privacy: .public)
        """
      )
    }
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

  private func subscribeToErrors(ctx: WKWebExtensionContext, name: String) {
    // AsyncSequence form keeps both producer and consumer inside the
    // MainActor isolation domain, sidestepping the Sendable barrier
    // that the block-based `addObserver(forName:object:queue:using:)`
    // trips in Swift 6 (the Notification argument is task-isolated and
    // cannot be handed to a MainActor closure safely).
    Task { @MainActor in
      let stream = NotificationCenter.default.notifications(
        named: WKWebExtensionContext.errorsDidUpdateNotification,
        object: ctx
      )
      for await _ in stream {
        Self.logErrors(ctx: ctx, source: "errorsDidUpdate")
      }
    }
    logger.debug("Subscribed to errorsDidUpdate for '\(name, privacy: .public)'")
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
