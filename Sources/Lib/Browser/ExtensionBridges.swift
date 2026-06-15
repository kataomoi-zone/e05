import AppKit
import WebKit

/// Bridges from e05's pane / workspace model to WebKit's
/// `WKWebExtensionWindow` / `WKWebExtensionTab` protocols. Both
/// protocols inherit `<NSObject>`, so direct conformance on the
/// `final class @MainActor` model types isn't possible without
/// dragging `NSObject` into the persistence layer — bridge objects
/// keep the model surface clean and let per-tab bridges be cached
/// per pane id without polluting `PaneModel` with WebExtension-only
/// fields.
///
/// e05 surfaces its browser panes to extensions as two windows: a
/// normal window holding the non-private workspaces' panes and a
/// private window holding the private workspaces'. Within a window,
/// workspace switches look like an active-tab change rather than a
/// window-focus change. Both windows stay identity-stable for the
/// host's process lifetime; pane bridges are cached by `PaneModel.id`
/// so repeated `tabs(for:)` walks return the same instance and
/// extension-side per-tab state survives popup re-opens. The split
/// exists because `WKWebExtensionWindow.isPrivate` is fixed per window
/// lifetime — see `WorkspaceExtensionBridge`.

/// Reports e05's browser panes to web extensions as a host window.
/// The controller keeps two stable instances — a normal window
/// (non-private workspaces) and a private window (private workspaces) —
/// because `WKWebExtensionWindow.isPrivate(for:)` is cached for a
/// window's lifetime and so can't flip on one instance. WebKit only
/// delivers the private window and its tabs to extensions whose
/// `WKWebExtensionContext.hasAccessToPrivateData` is set, so the split
/// is what isolates private browsing from un-granted extensions. Both
/// instances are held strongly by `ExtensionController` and handed back
/// from `openWindowsFor` / `focusedWindowFor` so identity (used by
/// `WKWebExtensionContext.openTabs`'s set semantics) stays stable.
@MainActor
final class WorkspaceExtensionBridge: NSObject, WKWebExtensionWindow {
  /// `true` for the private-browsing window (its tabs are the
  /// private-workspace panes), `false` for the normal window.
  let isPrivate: Bool

  init(isPrivate: Bool = false) {
    self.isPrivate = isPrivate
    super.init()
  }

  /// PaneContainer that owns the workspaces this bridge reports.
  /// Weak so the bridge doesn't keep the container alive past app
  /// teardown; nil means "no window yet" — every accessor returns
  /// the empty / inactive form so a controller load that races
  /// ahead of `bindContainer(_:)` doesn't crash.
  weak var container: PaneContainerViewController?

  /// Sticky reference to the most recent browser pane that was
  /// observed as the container's focused pane. Used as a fallback
  /// when `focusedPane` is nil or non-browser — a popup webView
  /// taking first responder shifts the focused pane out from under
  /// `chrome.tabs.query({active:true})` callers, leaving the
  /// extension with an empty result the moment its own popup opens.
  /// Updated synchronously by `refreshSticky()` whenever the bridge
  /// is queried, and at the boundary of every focus-changing path
  /// in `PaneContainerViewController` via `noteFocusChanged(_:)`.
  weak var stickyActiveBrowserPane: PaneModel?

  /// Whether `pane`'s workspace privacy matches this window, so the
  /// normal window only ever tracks / answers with non-private panes
  /// and the private window only private ones. Without this, focusing a
  /// private pane would overwrite the normal window's sticky too,
  /// blanking a non-granted extension's `tabs.query({active})` the
  /// moment the user switches into a private workspace.
  private func belongsToThisWindow(_ pane: PaneModel) -> Bool {
    container?.workspaceContaining(pane: pane)?.isPrivate == isPrivate
  }

  /// Resolve the browser pane that should answer "active tab"
  /// queries for this window. Prefers the live focused pane (when it's
  /// a browser pane in this window's privacy scope), otherwise falls
  /// back to the sticky reference so popup webViews and transient
  /// terminal-pane focus don't blank out `chrome.tabs.query({active})`.
  func currentBrowserPane() -> PaneModel? {
    refreshSticky()
    if let focused = container?.focusedPane, focused.address.kind == .browser,
      belongsToThisWindow(focused)
    {
      return focused
    }
    return stickyActiveBrowserPane
  }

  /// Snapshot the focused pane into `stickyActiveBrowserPane` if it's a
  /// browser pane in this window's privacy scope. No-op for a terminal /
  /// e05:// pane, or a pane belonging to the *other* window — the
  /// previous sticky value survives, which is the desired fallback for
  /// popup-driven focus shifts and cross-window focus changes.
  func refreshSticky() {
    if let focused = container?.focusedPane, focused.address.kind == .browser,
      belongsToThisWindow(focused)
    {
      stickyActiveBrowserPane = focused
    }
  }

  /// Direct hook called by `PaneContainerViewController` whenever
  /// focus moves. Lets the bridge keep `stickyActiveBrowserPane`
  /// fresh without depending on extension-side query timing. Each
  /// window only records panes in its own privacy scope.
  func noteFocusChanged(_ pane: PaneModel?) {
    if let pane, pane.address.kind == .browser, belongsToThisWindow(pane) {
      stickyActiveBrowserPane = pane
    }
  }

  func tabs(for _: WKWebExtensionContext) -> [any WKWebExtensionTab] {
    guard let container else { return [] }
    refreshSticky()
    var tabs: [any WKWebExtensionTab] = []
    for workspace in container.workspaces where workspace.isPrivate == isPrivate {
      for column in workspace.columns {
        for pane in column.panes where pane.address.kind == .browser {
          tabs.append(ExtensionController.shared.bridge(for: pane))
        }
      }
    }
    return tabs
  }

  /// The active tab *for this window*: the focused browser pane only
  /// when its workspace privacy matches this window's. WebKit asks both
  /// the normal and private window, so a private focused pane answers
  /// the private window (and `nil` for the normal one) and vice versa.
  func activeTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
    guard let pane = currentBrowserPane(),
      let container,
      let owning = container.workspaceContaining(pane: pane),
      owning.isPrivate == isPrivate
    else { return nil }
    return ExtensionController.shared.bridge(for: pane)
  }

  func isPrivate(for _: WKWebExtensionContext) -> Bool { isPrivate }

  // Default identity values — e05 is a single normal-state window;
  // there's no separate popup window, no minimised / maximised
  // bookkeeping for extensions to act on.
  func windowType(for _: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
  func windowState(for _: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }

  func frame(for _: WKWebExtensionContext) -> CGRect {
    container?.view.window?.frame ?? .zero
  }

  func screenFrame(for _: WKWebExtensionContext) -> CGRect {
    container?.view.window?.screen?.visibleFrame ?? .zero
  }
}

/// Per-pane bridge to `WKWebExtensionTab`. Cached by pane id inside
/// `ExtensionController` so repeated `tabs(for:)` walks hand out
/// the same instance — `WKWebExtensionContext.openTabs` is a
/// `Set<AnyHashable>` keyed off `NSObject` identity, so handing
/// back fresh instances on every query would orphan extension-side
/// per-tab state on every popup open.
@MainActor
final class PaneExtensionBridge: NSObject, WKWebExtensionTab {
  weak var pane: PaneModel?
  weak var container: PaneContainerViewController?

  init(pane: PaneModel, container: PaneContainerViewController?) {
    self.pane = pane
    self.container = container
  }

  func webView(for _: WKWebExtensionContext) -> WKWebView? {
    // No log here on purpose: extensions hammer this method (~1500/s
    // right after background-content load while content scripts are
    // injected across every tab), and a debug-level os.Logger call
    // per invocation backs up the unified log writer to the point of
    // visible UI hitching. The configuration-mismatch sanity check
    // we used to perform here didn't survive the reboot diagnosis —
    // it's a one-time invariant validated at load time, not a per-
    // call concern.
    pane?.browserView?.webView
  }

  func title(for _: WKWebExtensionContext) -> String? {
    pane?.title
  }

  func url(for _: WKWebExtensionContext) -> URL? {
    pane?.browserView?.webView.url ?? pane?.address.url
  }

  func isLoadingComplete(for _: WKWebExtensionContext) -> Bool {
    guard let webView = pane?.browserView?.webView else { return true }
    return !webView.isLoading
  }

  func isPinned(for _: WKWebExtensionContext) -> Bool { false }
  func isMuted(for _: WKWebExtensionContext) -> Bool {
    pane?.browserView?.isMuted ?? false
  }
  func isPlayingAudio(for _: WKWebExtensionContext) -> Bool {
    pane?.browserView?.isPlayingAudio ?? false
  }

  /// `chrome.tabs.update({muted: true/false})` lands here. Routes
  /// through the same `setMuted(_:)` path the URL bar / sidebar
  /// speaker uses, so the JS-injected `<audio>` / `<video>` flip
  /// and the `onAudioStateChanged` fan-out (URL bar refresh, sidebar
  /// indicator, extension change notification) all run uniformly
  /// regardless of whether the toggle came from a click or an
  /// extension API call.
  func setMuted(
    _ muted: Bool,
    for _: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let bv = pane?.browserView else {
      completionHandler(
        NSError(
          domain: "com.kawarimidoll.e05.Extensions",
          code: 8,
          userInfo: [NSLocalizedDescriptionKey: "Tab is no longer attached."]
        )
      )
      return
    }
    bv.setMuted(muted)
    completionHandler(nil)
  }
  func isReaderModeActive(for _: WKWebExtensionContext) -> Bool { false }
  // `isSelected(for:)` is intentionally not implemented: WebKit's
  // documented default is "YES for the active tab and NO for other
  // tabs" (WKWebExtensionTab.h:342). Sourcing it from
  // `WorkspaceExtensionBridge.activeTab(for:)`, which already
  // honours the sticky-active-pane fallback, keeps every active-tab
  // query consistent without a second source of truth that could
  // disagree during popup-driven focus shifts.

  /// Resolve the window that contains this tab. Without this,
  /// WebKit's `chrome.tabs.query({currentWindow: true})` filter
  /// loses the tab→window association — `windowId` arrives at
  /// extensions as `-1` and the active-tab query returns an empty
  /// set even when `tabs(for:)` enumerates tabs correctly. A pane in a
  /// private workspace belongs to the private window so its privacy is
  /// reported correctly; everything else belongs to the normal window.
  func window(for _: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
    let isPrivate = pane.flatMap { container?.workspaceContaining(pane: $0)?.isPrivate } ?? false
    return isPrivate
      ? ExtensionController.shared.privateWorkspaceBridge
      : ExtensionController.shared.workspaceBridge
  }

  /// Bypass standard host permission checks. e05 already auto-grants
  /// every requested URL / match pattern through the controller
  /// delegate; this is the per-tab counterpart that lets extensions
  /// declaring only `content_scripts.matches` (without explicit
  /// `host_permissions`) reach `chrome.tabs.sendMessage` against
  /// their content scripts. Without it, content scripts inject but
  /// runtime tab messaging gets rejected.
  func shouldBypassPermissions(for _: WKWebExtensionContext) -> Bool { true }

  func size(for _: WKWebExtensionContext) -> CGSize {
    pane?.browserView?.webView.frame.size ?? .zero
  }

  func zoomFactor(for _: WKWebExtensionContext) -> Double {
    Double(pane?.browserView?.webView.pageZoom ?? 1.0)
  }

  /// Index of this pane among the host's browser panes, flattened
  /// across workspaces and columns. Extensions sometimes use the
  /// index to reorder tabs or pick the next/previous one; returning
  /// a stable monotonically-increasing index per snapshot is enough
  /// for those callers without committing to a workspace-wide id
  /// scheme.
  func indexInWindow(for _: WKWebExtensionContext) -> Int {
    guard let pane, let container else { return 0 }
    var index = 0
    for workspace in container.workspaces {
      for column in workspace.columns {
        for sibling in column.panes where sibling.address.kind == .browser {
          if sibling === pane { return index }
          index += 1
        }
      }
    }
    return 0
  }

  /// `chrome.tabs.update({active: true})` lands here. Route through
  /// the container's existing focus path so cross-workspace and
  /// cross-column navigation stays consistent with palette / sidebar
  /// activation.
  func activate(
    for _: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let pane, let container else {
      completionHandler(
        NSError(
          domain: "com.kawarimidoll.e05.Extensions",
          code: 7,
          userInfo: [NSLocalizedDescriptionKey: "Tab is no longer attached."]
        )
      )
      return
    }
    container.focusPane(id: pane.id)
    completionHandler(nil)
  }

  /// `chrome.tabs.reload()` — route through `BrowserPaneView`'s
  /// reload helpers so a suspended pane wakes up via the same
  /// single-decision-site branch that the URL bar reload button,
  /// the global Reload action, and the placeholder Reload button
  /// use. Reloading the bare `WKWebView` directly would silently
  /// no-op on a suspended pane because the web view is detached.
  func reload(
    fromOrigin: Bool,
    for _: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let bv = pane?.browserView else {
      completionHandler(nil)
      return
    }
    if fromOrigin {
      bv.reloadFromOrigin()
    } else {
      bv.reload()
    }
    completionHandler(nil)
  }

  /// `chrome.tabs.update({url: ...})` — load via the underlying
  /// WKWebView. The pane's URL bar updates through the existing
  /// KVO observer chain, so no extra notification is required here.
  func loadURL(
    _ url: URL,
    for _: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let webView = pane?.browserView?.webView else {
      completionHandler(nil)
      return
    }
    webView.load(URLRequest(url: url))
    completionHandler(nil)
  }

  func goBack(
    for _: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    pane?.browserView?.goBack()
    completionHandler(nil)
  }

  func goForward(
    for _: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    pane?.browserView?.goForward()
    completionHandler(nil)
  }
}
