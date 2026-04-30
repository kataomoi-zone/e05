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
/// niri-style WMs treat all workspaces as one continuous editing
/// surface, so e05 surfaces every browser pane across every
/// workspace as a single "window" to extensions. Workspace switches
/// then look like an active-tab change rather than a window-focus
/// change. The single window stays identity-stable for the host's
/// process lifetime; pane bridges are cached by `PaneModel.id` so
/// repeated `tabs(for:)` walks return the same instance and
/// extension-side per-tab state survives popup re-opens.

/// Reports e05's browser panes to web extensions as the single
/// host window. Held strongly by `ExtensionController`; the
/// controller hands the same instance back from
/// `openWindowsFor` / `focusedWindowFor` on every query so identity
/// (used by `WKWebExtensionContext.openTabs`'s set semantics) stays
/// stable.
@MainActor
final class WorkspaceExtensionBridge: NSObject, WKWebExtensionWindow {
  /// PaneContainer that owns the workspaces this bridge reports.
  /// Weak so the bridge doesn't keep the container alive past app
  /// teardown; nil means "no window yet" — every accessor returns
  /// the empty / inactive form so a controller load that races
  /// ahead of `bindContainer(_:)` doesn't crash.
  weak var container: PaneContainerViewController?

  func tabs(for _: WKWebExtensionContext) -> [any WKWebExtensionTab] {
    guard let container else { return [] }
    var tabs: [any WKWebExtensionTab] = []
    for workspace in container.workspaces {
      for column in workspace.columns {
        for pane in column.panes where pane.address.kind == .browser {
          tabs.append(ExtensionController.shared.bridge(for: pane))
        }
      }
    }
    return tabs
  }

  func activeTab(for _: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
    guard let container, let pane = container.focusedPane,
      pane.address.kind == .browser
    else { return nil }
    return ExtensionController.shared.bridge(for: pane)
  }

  func isPrivate(for _: WKWebExtensionContext) -> Bool { false }

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
  func isMuted(for _: WKWebExtensionContext) -> Bool { false }
  func isPlayingAudio(for _: WKWebExtensionContext) -> Bool { false }
  func isReaderModeActive(for _: WKWebExtensionContext) -> Bool { false }
  func isSelected(for _: WKWebExtensionContext) -> Bool {
    guard let pane, let container else { return false }
    return container.focusedPane?.id == pane.id
  }

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

  /// `chrome.tabs.reload()` — defer to the underlying WKWebView so
  /// the existing reload pipeline (loading-state callback, URL bar
  /// stop button, network observers) fires uniformly.
  func reload(
    fromOrigin: Bool,
    for _: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard let webView = pane?.browserView?.webView else {
      completionHandler(nil)
      return
    }
    if fromOrigin {
      webView.reloadFromOrigin()
    } else {
      webView.reload()
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
    pane?.browserView?.webView.goBack()
    completionHandler(nil)
  }

  func goForward(
    for _: WKWebExtensionContext,
    completionHandler: @escaping (Error?) -> Void
  ) {
    pane?.browserView?.webView.goForward()
    completionHandler(nil)
  }
}
