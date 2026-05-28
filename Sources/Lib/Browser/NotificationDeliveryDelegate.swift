import AppKit
import UserNotifications
import WebKit
import os.log

private let logger = Logger(
  subsystem: LogSubsystem.app, category: "Notifications"
)

/// Bridges Web Notifications fired through `WKWebsiteDataStore` into
/// macOS-native banners via `UNUserNotificationCenter`, and routes
/// banner taps back to the browser container so the notification's
/// origin opens as a new column.
///
/// `_WKWebsiteDataStoreDelegate` is SPI; the protocol symbol isn't
/// exposed in Swift. WebKit dispatches via `-respondsToSelector:`,
/// so an `@objc` method with the matching selector is sufficient —
/// no formal protocol conformance is needed. The same applies to
/// `_WKNotificationData`: its properties are read via KVC since the
/// class isn't importable.
///
/// `WKWebsiteDataStore._delegate` is `weak`, so the owner (currently
/// `AppDelegate`) must keep a strong reference for the lifetime of
/// the application.
///
/// Known limitations:
/// - `clients.openWindow(url)` from a Service Worker has no host
///   hook on macOS (the call silently no-ops). The fallback's
///   `addColumn` covers the user-visible path — a SW that wanted a
///   fresh window ends up with one opened by us, just without the
///   SW being able to influence the destination URL beyond what it
///   stashed in `notification.data`.
/// - Only `WKWebsiteDataStore.default()` is wired. Private workspaces
///   use their own `nonPersistent()` data store with no `_delegate`
///   attached — intentional, since persistent notifications conflict
///   with private mode. `firstPane(matchingHost:)` additionally
///   filters out private workspaces so a public-origin click can't
///   land on a private pane (or the reverse).
/// - `_WKNotificationData.icon` is not on the public SPI surface; it
///   only appears in `dictionaryRepresentation()["iconURL"]`. We
///   don't fetch or attach it yet, so banners use the default app
///   icon.
@MainActor
public final class NotificationDeliveryDelegate: NSObject {
  /// Container that receives `addColumn` on banner tap. `weak` so a
  /// future multi-window pivot can't pin a stale view controller.
  public weak var container: PaneContainerViewController?

  /// `UNNotificationContent.userInfo` key under which we stash the
  /// page URL at display time. The banner-tap handler reads it back
  /// because `_WKNotificationData` is gone by the time the user
  /// interacts with the notification.
  private static let userInfoURLKey = "e05.notification.url"

  /// `UNNotificationContent.userInfo` key under which we stash
  /// `_WKNotificationData.dictionaryRepresentation` at display time.
  /// The click handler hands this back to WebKit so a real
  /// `notificationclick` event reaches the originating Service
  /// Worker — letting Slack / Discord / GitHub etc. dispatch their
  /// own deep-link navigation just like Safari does.
  private static let userInfoDictKey = "e05.notification.dict"

  /// SPI selector for routing a banner click into WebKit's
  /// notification subsystem. Looked up at runtime so a future macOS
  /// that retires the SPI degrades to the URL fallback rather than
  /// crashing. Signature:
  /// `-(void)_processPersistentNotificationClick:(NSDictionary *)dict
  ///                          completionHandler:(void(^)(bool))handler`
  /// (`Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStorePrivate.h`,
  /// macos 13.0+).
  private static let dispatchClickSelector = NSSelectorFromString(
    "_processPersistentNotificationClick:completionHandler:"
  )

  public init(container: PaneContainerViewController) {
    self.container = container
    super.init()
    Self.requestSystemAuthorization()
  }

  /// Build the delegate, attach it to `WKWebsiteDataStore.default()`
  /// via the `_delegate` SPI, and wire `UNUserNotificationCenter`
  /// in one call. Returns `nil` (and logs) when the SPI is
  /// unavailable so callers degrade to "no Web Notifications this
  /// session" rather than crashing on a future macOS that retires
  /// the SPI.
  ///
  /// The caller must keep the returned reference alive for the
  /// app's lifetime — `_delegate` is `weak` on WebKit's side, so a
  /// dropped strong ref silently severs every subsequent display.
  public static func install(container: PaneContainerViewController)
    -> NotificationDeliveryDelegate?
  {
    let getter = NSSelectorFromString("_delegate")
    let setter = NSSelectorFromString("set_delegate:")
    let store = WKWebsiteDataStore.default()
    guard store.responds(to: getter), store.responds(to: setter) else {
      logger.error(
        "[notification/attach] WKWebsiteDataStore._delegate SPI is unavailable; Web Notifications will not be wired this session"
      )
      return nil
    }
    let delegate = NotificationDeliveryDelegate(container: container)
    store.setValue(delegate, forKey: "_delegate")
    // Round-trip the value back — `_delegate` is `weak`, so a
    // silent KVC failure (typo / misshapen ivar) would lose the
    // reference and break dispatch later with no other signal.
    let attached = store.value(forKey: "_delegate") as AnyObject?
    if attached !== delegate {
      logger.error(
        "[notification/attach] _delegate setValue did not stick; got \(String(describing: attached), privacy: .public)"
      )
    }
    UNUserNotificationCenter.current().delegate = delegate
    return delegate
  }

  // MARK: - System authorization

  /// Ask macOS for permission to display banners / play sound at app
  /// launch. This is the OS-level gate; the per-site Web Notification
  /// permission (`requestNotificationPermissionForSecurityOrigin:`) is
  /// the secondary gate that's recorded in `PermissionsStore`. Both
  /// must be granted for a banner to actually appear.
  ///
  /// Failure is logged, not fatal — a denied OS grant still lets us
  /// record per-site decisions for when the user later allows e05 in
  /// System Settings > Notifications.
  private static func requestSystemAuthorization() {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { granted, error in
      if let error {
        logger.error(
          "[notification/authorize] failed: \(error.localizedDescription, privacy: .public)"
        )
      } else {
        logger.info("[notification/authorize] granted=\(granted)")
      }
    }
  }

  // MARK: - _WKWebsiteDataStoreDelegate SPI

  /// Seed WebKit's notification permission state from
  /// `PermissionsStore` when the delegate is first attached. WebKit
  /// calls this once after `_delegate` is set. The return map is
  /// keyed on origin string (`scheme://host`); we emit `https://`
  /// only because Web Notifications requires a secure context per
  /// spec (Service Worker notifications mandate HTTPS), so a plain
  /// http host that somehow reached `requestPermission()` shouldn't
  /// be auto-granted across sessions.
  @objc(notificationPermissionsForWebsiteDataStore:)
  public func notificationPermissions(
    for _: WKWebsiteDataStore
  ) -> [String: NSNumber] {
    var map: [String: NSNumber] = [:]
    let store = PermissionsStore.shared
    for host in store.allHosts {
      guard let state = store.state(for: host, kind: .notification) else {
        continue
      }
      map["https://" + host] = NSNumber(value: state == .grant)
    }
    return map
  }

  /// WebKit pushes a notification for the host to display. Bridge to
  /// `UNUserNotificationCenter` so it appears as a native banner /
  /// Notification Center entry.
  @objc(websiteDataStore:showNotification:)
  public func websiteDataStore(
    _: WKWebsiteDataStore,
    showNotification notificationData: NSObject
  ) {
    // KVC access — `_WKNotificationData` isn't declared in the public
    // SDK so we can't import the symbol. Property names taken from
    // `Source/WebKit/UIProcess/API/Cocoa/_WKNotificationData.h` in
    // WebKit trunk.
    let title = (notificationData.value(forKey: "title") as? String) ?? ""
    let body = (notificationData.value(forKey: "body") as? String) ?? ""
    // Strip any embedded NUL so a hostile `tag` can't collide with
    // the `<origin>\u{0}<tag>` request identifier of a different
    // origin. Web Notifications spec allows arbitrary strings.
    let tag = ((notificationData.value(forKey: "tag") as? String) ?? "")
      .replacingOccurrences(of: "\u{0}", with: "")
    let origin = (notificationData.value(forKey: "origin") as? String) ?? ""
    let identifier =
      (notificationData.value(forKey: "identifier") as? String) ?? ""
    let uuid = notificationData.value(forKey: "uuid") as? UUID
    let securityOrigin = notificationData.value(forKey: "securityOrigin") as? URL

    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default

    // Capture the full dictionary representation so the click
    // handler can hand it back to WebKit, letting WebKit dispatch
    // `notificationclick` to the originating Service Worker. The
    // SW's JS owns the real click semantics (picking the right
    // channel / thread / message) — we can't replicate that by
    // reading the data field directly.
    //
    // `UNNotificationContent.userInfo` is persisted to disk by
    // UN so a click after app restart can still resolve. The
    // store only accepts plist-safe values; validate before
    // stashing so an unexpected NSValue / object reference in
    // the dict can't silently break the cross-launch path. When
    // the dict is missing or invalid, the fallback URL path
    // still works.
    let dictSelector = NSSelectorFromString("dictionaryRepresentation")
    if notificationData.responds(to: dictSelector),
      let dict = notificationData.perform(dictSelector)?.takeUnretainedValue()
        as? NSDictionary
    {
      if PropertyListSerialization.propertyList(dict, isValidFor: .binary) {
        content.userInfo[Self.userInfoDictKey] = dict
      } else {
        logger.warning(
          "[notification/persist] dictionaryRepresentation not plist-safe; SW dispatch will skip this notification (origin=\(origin, privacy: .public))"
        )
      }
    }

    // Fallback click target for the no-SW case (page-context
    // `new Notification(...)` without a Service Worker, or SW
    // dispatch returning `false`). Best-effort scan of common deep
    // link keys in `data`, otherwise the security origin.
    let clickURL =
      Self.extractDeepLink(
        from: notificationData.value(forKey: "userInfo") as? [AnyHashable: Any]
      ) ?? securityOrigin ?? (origin.isEmpty ? nil : URL(string: origin))
    if let clickURL {
      content.userInfo[Self.userInfoURLKey] = clickURL.absoluteString
    }

    // Web Notifications spec: (origin, tag) identifies a notification
    // slot — a fresh notification with the same tag from the same
    // origin replaces the previous one. UN center replaces by request
    // identifier, so combining origin + tag gives equivalent
    // semantics. NUL separator avoids `"a:b"` vs `"a:" + ":b"`
    // collisions in pathological inputs.
    let requestIdentifier: String
    if !tag.isEmpty {
      requestIdentifier = "\(origin)\u{0}\(tag)"
    } else if !identifier.isEmpty {
      requestIdentifier = identifier
    } else {
      requestIdentifier = uuid?.uuidString ?? UUID().uuidString
    }

    let request = UNNotificationRequest(
      identifier: requestIdentifier, content: content, trigger: nil
    )
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        logger.error(
          "[notification/display] add failed for \(origin, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }

  /// Declarative-Web-Push click path. WebKit only invokes this when
  /// `ENABLE(DECLARATIVE_WEB_PUSH)` is on and the notification has a
  /// `navigateURL` payload (`WKWebsiteDataStore.mm:285-291`). Standard
  /// `new Notification()` clicks do NOT route through this selector —
  /// they reach `userNotificationCenter(_:didReceive:)` instead.
  /// Implemented for forward compatibility; the same `openURL` is
  /// fine for both paths.
  @objc(websiteDataStore:navigateToNotificationActionURL:)
  public func websiteDataStore(
    _: WKWebsiteDataStore, navigateToNotificationActionURL url: URL
  ) {
    openURL(url)
  }

  // MARK: - Internal

  /// Route the notification click.
  ///
  /// - **Existing pane on the same host**: focus it (switching
  ///   workspaces if needed), and if the click URL is a deep link
  ///   (path / query / fragment beyond the bare origin) **also**
  ///   navigate that pane to it. A Slack mention banner therefore
  ///   lands on the right channel instead of leaving the user on
  ///   whatever Slack last showed.
  /// - **No matching pane**: open the URL in a fresh column.
  ///
  /// A bare-origin click URL (`https://app.slack.com` with no path)
  /// is intentionally not used for navigation when a pane already
  /// exists — overwriting the user's current channel position with
  /// the site's landing page is worse than just focusing the
  /// existing state.
  fileprivate func openURL(_ url: URL, allowRedirect: Bool = true) {
    guard let container else { return }
    let host = url.host?.lowercased() ?? ""
    if !host.isEmpty,
      let pane = Self.firstPane(matchingHost: host, in: container)
    {
      container.switchToPane(id: pane.id)
      if allowRedirect, Self.isDeepLink(url),
        pane.address.url.absoluteString != url.absoluteString
      {
        pane.browserView?.navigate(to: url.absoluteString, transition: .link)
      }
      return
    }
    container.addColumn(address: PaneAddress(url))
  }

  /// First non-private pane whose address host matches `host`.
  /// `nil` when no pane is on the host. Lookup spans every public
  /// workspace because a notification should focus the existing
  /// tab regardless of which workspace it lives in; same-host
  /// panes in multiple workspaces tie-break by traversal order
  /// (workspace 0 wins).
  ///
  /// **Private workspaces are intentionally skipped.** Letting a
  /// public-origin notification land on a private pane (or
  /// vice-versa) would cross the privacy boundary — a private
  /// workspace exists precisely to keep its hosts separated from
  /// the rest of the session. Notifications from private panes
  /// already shouldn't fire here since private workspaces use
  /// their own ephemeral `WKWebsiteDataStore`, but the guard is
  /// the belt-and-braces.
  private static func firstPane(
    matchingHost host: String, in container: PaneContainerViewController
  ) -> PaneModel? {
    for workspace in container.workspaces {
      if workspace.isPrivate { continue }
      for column in workspace.columns {
        for pane in column.panes {
          guard let paneHost = pane.address.url.host?.lowercased() else { continue }
          if paneHost == host { return pane }
        }
      }
    }
    return nil
  }

  /// True when the URL points somewhere beyond the bare origin
  /// (has a non-`/` path, a query, or a fragment). Used to decide
  /// whether a click should redirect an existing pane or just focus
  /// it — bare-origin URLs aren't worth losing per-pane state for.
  private static func isDeepLink(_ url: URL) -> Bool {
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return !path.isEmpty || url.query != nil || url.fragment != nil
  }

  /// Pick the click destination URL out of the page-supplied `data`
  /// dict. Web Notifications doesn't standardise where the deep link
  /// lives, but a small set of keys covers the common cases (raw
  /// `url` / `link`, plus the FCM-style `click_action` /
  /// `default_action`). Strings are parsed as URLs; the first
  /// successful parse wins. Returns `nil` if `data` is missing or
  /// has none of the recognised keys.
  private static func extractDeepLink(from userInfo: [AnyHashable: Any]?)
    -> URL?
  {
    guard let userInfo else { return nil }
    let keys = ["url", "link", "click_action", "default_action"]
    for key in keys {
      guard let raw = userInfo[key] as? String, let url = URL(string: raw),
        url.scheme == "http" || url.scheme == "https"
      else { continue }
      return url
    }
    return nil
  }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationDeliveryDelegate: @MainActor UNUserNotificationCenterDelegate {
  /// Show the banner even when e05 is foreground. UN's default is to
  /// suppress in-app to avoid double-showing; for a browser, the
  /// notification originates from a page the user may not be looking
  /// at, so foreground-suppress hides useful signals (Slack DM while
  /// reading docs in another column, etc.).
  public func userNotificationCenter(
    _: UNUserNotificationCenter,
    willPresent _: UNNotification,
    withCompletionHandler completionHandler:
      @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .list])
  }

  /// Banner tap. First tries to dispatch a real `notificationclick`
  /// event into WebKit via SPI so a Service Worker can drive
  /// deep-link navigation itself (Slack mention → the mentioned
  /// channel, Gmail notification → the right thread, etc.). When
  /// the SPI is unavailable or the SW chooses not to handle the
  /// click, falls back to opening the stashed URL ourselves.
  public func userNotificationCenter(
    _: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    let dict = userInfo[Self.userInfoDictKey] as? NSDictionary
    let store = WKWebsiteDataStore.default()

    if let dict, store.responds(to: Self.dispatchClickSelector) {
      // The completion block runs on whatever queue WebKit invokes
      // it from. Captures cross that hop and have to be flagged
      // unchecked-Sendable; userInfo / completionHandler are both
      // MainActor-local by construction and the block only reads
      // them, so the unsafety is a documented promise rather than
      // an actual race.
      nonisolated(unsafe) let capturedCompletion = completionHandler
      nonisolated(unsafe) let capturedUserInfo = userInfo
      let onComplete: @convention(block) @Sendable (Bool) -> Void = {
        [weak self] handled in
        Task { @MainActor in
          defer { capturedCompletion() }
          self?.fallbackClickRoute(userInfo: capturedUserInfo, swHandled: handled)
        }
      }
      store.perform(
        Self.dispatchClickSelector, with: dict, with: onComplete as Any
      )
      return
    }

    fallbackClickRoute(userInfo: userInfo, swHandled: false)
    completionHandler()
  }

  /// Always runs after WebKit's SW dispatch (or instead of it when
  /// the SPI is unavailable). The dispatch alone is not enough — a
  /// SW that closes the notification without navigating, or a SW
  /// that calls `clients.openWindow(url)` (whose macOS host hook
  /// isn't wired yet), leaves the user with no visible feedback.
  /// This fallback guarantees that either an existing pane is
  /// focused or a new column is opened.
  ///
  /// `swHandled` gates the deep-link redirect inside `openURL`: when
  /// WebKit reports the SW handled the click (`handled=true`), the
  /// SW has already chosen where the existing pane should land
  /// (typically via `client.navigate`) so we must not overwrite
  /// that decision with our own best-effort URL. When the SW didn't
  /// handle (or there's no SW at all), our stashed URL is the only
  /// signal we have, so deep-link redirect is allowed.
  fileprivate func fallbackClickRoute(
    userInfo: [AnyHashable: Any], swHandled: Bool
  ) {
    guard
      let raw = userInfo[Self.userInfoURLKey] as? String,
      let url = URL(string: raw)
    else { return }
    openURL(url, allowRedirect: !swHandled)
  }
}
