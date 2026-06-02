import AppKit
import WebKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BrowserContextMenu")

/// Right-click context menu customisation for browser panes.
///
/// **Private SPI dependency**: macOS WKWebView exposes no public API
/// for mutating the right-click menu. The official `WKUIDelegate`
/// context-menu hooks are gated behind `TARGET_OS_IOS`. To filter
/// the macOS menu we adopt the SPI declared in `WKUIDelegatePrivate.h`:
///
/// ```objc
/// - (void)_webView:(WKWebView *)webView
///   getContextMenuFromProposedMenu:(NSMenu *)menu
///   forElement:(_WKContextMenuElementInfo *)element
///   userInfo:(id <NSSecureCoding>)userInfo
///   completionHandler:(void (^)(NSMenu *))completionHandler;
/// ```
///
/// Bridge from Swift via `@objc(...)` name override on a method
/// whose signature matches the selector exactly. Element data
/// (the link URL) is read off `_WKContextMenuElementInfo` via the
/// `hitTestResult` → `_WKHitTestResult.absoluteLinkURL` two-hop
/// (the element class itself does not expose `linkURL` directly,
/// despite the iOS-public counterpart doing so).
///
/// This file documents the dependency in one place so future Apple
/// releases that rename or remove the SPI surface have a single
/// audit point. e05 is self-distributed (not App Store), and the
/// project already depends on multiple WebKit SPIs (`_inspector`,
/// `developerExtrasEnabled`); this addition stays within the same
/// risk envelope.
///
/// Failure mode if the SPI breaks in a future macOS:
/// - Swift method silently stops being invoked (signature mismatch
///   on WebKit's side); the default macOS context menu reappears
///   unchanged. No crash.
/// - The hitTestResult / absoluteLinkURL probes guard with
///   `responds(to:)` and bail with `nil`; the link-context menu
///   items aren't appended but nothing else breaks.
///
/// Detection: `NSLog` lines inside the delegate dump the proposed
/// menu's titles and selectors plus the link-URL probe outcome, so
/// a quick run with `2>&1 | grep '\[e05/ctxmenu\]'` shows whether
/// the SPI is still being called and what selectors WebKit is
/// shipping.
extension BrowserPaneView {
  /// Candidate selectors that have shipped on the "Open Link in New
  /// Window" item across WebKit versions. macOS 26 ships the
  /// `WKMenuItemIdentifier`-driven action wrapper rather than the
  /// historical `_openLinkInNewWindow:` selector, so a single
  /// selector match is no longer sufficient. Stringified to keep
  /// SPI selectors out of the call sites.
  private static let openInNewWindowSelectors: Set<Selector> = [
    Selector(("_openLinkInNewWindow:")),
    Selector(("openLinkInNewWindow:")),
    Selector(("_WKMenuItemActionOpenLinkInNewWindow")),
  ]

  /// `NSMenuItem.identifier` strings shipped by WebKit for the
  /// "Open Link in New Window" item. Newer macOS versions
  /// (≥macOS 13) tag every default item with a `WKMenuItemIdentifier`
  /// raw string; matching on identifier is more stable than
  /// selector-matching across SDK changes.
  private static let openInNewWindowIdentifiers: Set<String> = [
    "WKMenuItemIdentifierOpenLinkInNewWindow"
  ]

  /// `@objc` name override binds this Swift method to WebKit's
  /// underscored selector. The argument labels match the selector
  /// piece-by-piece, otherwise WebKit's `respondsToSelector:` check
  /// fails and the method is never invoked.
  @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
  public func _webView(
    _: WKWebView,
    getContextMenuFromProposedMenu menu: NSMenu,
    forElement element: NSObject,
    userInfo _: NSSecureCoding?,
    completionHandler: @escaping (NSMenu?) -> Void
  ) {
    let linkURL = Self.linkURL(from: element)

    logger.debug(
      "proposed menu items=\(menu.items.count) linkURL=\(linkURL?.absoluteString ?? "nil", privacy: .public)"
    )
    for item in menu.items {
      logger.debug(
        "  item title=\(item.title, privacy: .public) action=\(item.action.map(NSStringFromSelector) ?? "nil", privacy: .public) identifier=\(item.identifier?.rawValue ?? "nil", privacy: .public)"
      )
    }

    // Drop "Open Link in New Window" — e05 is a single-window app
    // (workspaces replace separate windows). Match by selector OR
    // by `WKMenuItemIdentifier` raw string so the filter survives
    // both selector renames and identifier-only items.
    menu.items.removeAll { item in
      if let action = item.action, Self.openInNewWindowSelectors.contains(action) {
        return true
      }
      if let identifier = item.identifier?.rawValue,
        Self.openInNewWindowIdentifiers.contains(identifier)
      {
        return true
      }
      return false
    }

    if let url = linkURL {
      let separator = NSMenuItem.separator()
      let openInPaneItem = NSMenuItem(
        title: "Open Link in New Pane",
        action: #selector(e05OpenLinkInPane(_:)),
        keyEquivalent: "")
      openInPaneItem.target = self
      openInPaneItem.representedObject = url
      // `rectangle.split.2x1` reads as "another column joins this
      // one" — matches the new-pane = new-column UX policy used by
      // bookmarks/history panels and Cmd-click navigation.
      openInPaneItem.image = NSImage(
        systemSymbolName: "rectangle.split.2x1",
        accessibilityDescription: nil)
      let openInWorkspaceItem = NSMenuItem(
        title: "Open Link in New Workspace",
        action: #selector(e05OpenLinkInWorkspace(_:)),
        keyEquivalent: "")
      openInWorkspaceItem.target = self
      openInWorkspaceItem.representedObject = url
      // `square.on.square` reads as "another layer added on top" —
      // mirrors the workspace stack metaphor (workspaces slide up
      // and down vertically, building a stack visually).
      openInWorkspaceItem.image = NSImage(
        systemSymbolName: "square.on.square",
        accessibilityDescription: nil)
      menu.items.append(separator)
      menu.items.append(openInPaneItem)
      menu.items.append(openInWorkspaceItem)
    }

    completionHandler(menu)
  }

  /// Probe `_WKContextMenuElementInfo` for the clicked link's URL.
  ///
  /// `_WKContextMenuElementInfo` does **not** expose `linkURL` itself
  /// (verified against WebKit/WebKit `main`, header
  /// `_WKContextMenuElementInfo.h`); it only carries a `hitTestResult`
  /// of type `_WKHitTestResult`, which in turn exposes
  /// `absoluteLinkURL`. Both classes are SPI, so the access goes via
  /// `responds(to:)` + `perform(_:)` with stringified selectors —
  /// every step bails to `nil` on mismatch, so a future signature
  /// change downgrades the link-aware menu items rather than
  /// crashing the app.
  ///
  /// `valueForKey:` is intentionally avoided here: it raises
  /// `NSUnknownKeyException` on any non-KVC-compliant property,
  /// which is exactly the crash this function replaces.
  private static func linkURL(from element: NSObject) -> URL? {
    let hitSel = NSSelectorFromString("hitTestResult")
    guard element.responds(to: hitSel),
      let hit = element.perform(hitSel)?.takeUnretainedValue() as? NSObject
    else { return nil }
    let urlSel = NSSelectorFromString("absoluteLinkURL")
    guard hit.responds(to: urlSel),
      let url = hit.perform(urlSel)?.takeUnretainedValue() as? URL,
      !url.absoluteString.isEmpty
    else { return nil }
    return url
  }

  @objc fileprivate func e05OpenLinkInPane(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    onOpenInNewPane?(url)
  }

  @objc fileprivate func e05OpenLinkInWorkspace(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    onOpenInNewWorkspace?(url)
  }
}
