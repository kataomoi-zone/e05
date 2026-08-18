import AppKit
import Testing
import WebKit

@testable import E05Lib

@Suite("PaneModel")
@MainActor
struct PaneModelTests {
  /// A pane answering a `window.open` is handed back to WebKit, which
  /// then runs the navigation itself. Loading the address here as well
  /// would replace that navigation with a second one and drop the POST
  /// body a form-driven sign-in hands over — a failure that only shows
  /// up on the sign-in flows this path exists for, so the two cases are
  /// pinned side by side.
  @Test("a pane built for a window.open leaves the navigation to WebKit")
  func adoptedPaneLeavesTheLoadToWebKit() {
    let address = PaneAddress(URL(string: "https://example.com/oauth")!)

    let ownLoad = PaneModel(address: address, ghosttyApp: nil)
    #expect(ownLoad.browserView?.webView.isLoading == true)

    let adopted = PaneModel(
      address: address, ghosttyApp: nil,
      dependencies: .init(openerConfiguration: WKWebViewConfiguration()))
    #expect(adopted.browserView?.webView.isLoading == false)
  }

  /// The configuration WebKit hands over arrives sharing the opening
  /// pane's user content controller, and the handlers registered on it
  /// are per-pane: the hover-link overlay, the horizontal scroll edge,
  /// and the mute channel keyed by the pane's own UUID. Left shared,
  /// this pane's messages would arrive at its opener.
  @Test("a pane built for a window.open gets its own script handlers")
  func adoptedPaneDoesNotShareTheOpenersHandlers() {
    let address = PaneAddress(URL(string: "https://example.com/oauth")!)
    let opener = WKWebViewConfiguration()
    // Held before the first pane is built: the swap happens on the
    // configuration object the caller passed, so reading the field
    // afterwards returns whichever controller was installed last, not
    // the one the opener arrived with.
    let openerController = opener.userContentController

    let first = PaneModel(
      address: address, ghosttyApp: nil,
      dependencies: .init(openerConfiguration: opener))
    let second = PaneModel(
      address: address, ghosttyApp: nil,
      dependencies: .init(openerConfiguration: opener))

    let firstController = first.browserView?.webView.configuration.userContentController
    let secondController = second.browserView?.webView.configuration.userContentController
    #expect(firstController !== openerController)
    // Two panes opened from the same page must not share one either.
    #expect(firstController !== secondController)
  }

  @Test("unknown e05 addresses fall back to a blank browser pane")
  func unknownFallsBackToBlankBrowser() {
    // Retired addresses previously carried dedicated panes but now
    // resolve to `.unknown`. Session restore must keep working with
    // old entries still in `session.json`, so the init path lands
    // them on a blank browser instead of trapping.
    let retired = ["e05://history", "e05://bookmarks", "e05://downloads"]
    for urlString in retired {
      guard let address = PaneAddress(urlString) else {
        Issue.record("Failed to build PaneAddress from \(urlString)")
        continue
      }
      #expect(address.kind == .unknown)

      let pane = PaneModel(address: address, ghosttyApp: nil)
      #expect(pane.browserView != nil)
      #expect(pane.terminalView == nil)
      // The address itself is retained on the pane so the URL bar
      // keeps showing what the session restored, even if we
      // present it over a blank browser view.
      #expect(pane.address.url.absoluteString == urlString)
    }
  }

  @Test("settings address falls back to a blank browser pane")
  func settingsFallsBackToBlankBrowser() {
    // `.settings` is reserved for a future Settings pane but isn't
    // implemented yet. The init path must not trap on it so typing
    // `e05://settings` into the URL bar or restoring a session
    // referencing it behaves like any other unknown-ish destination.
    let pane = PaneModel(address: .settings, ghosttyApp: nil)
    #expect(pane.browserView != nil)
    #expect(pane.terminalView == nil)
    #expect(pane.address.kind == .settings)
  }

  @Test("find bar starts collapsed on a freshly built pane")
  func findBarStartsCollapsed() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    #expect(!pane.isFindBarVisible)
  }

  @Test("setFindBarVisible flips the flag in both directions")
  func setFindBarVisibleTogglesFlag() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    // The actual show/hide animation lives on a child NSPanel and is
    // skipped when the pane is not yet attached to a window, so the
    // unit-level contract is the public flag — the panel-side fade is
    // covered indirectly by the panel itself.
    pane.setFindBarVisible(true)
    #expect(pane.isFindBarVisible)
    pane.setFindBarVisible(false)
    #expect(!pane.isFindBarVisible)
  }

  @Test("setFindBarVisible with the same value is a no-op")
  func setFindBarVisibleIdempotent() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    // Re-applying the default must not drive spurious panel orderings
    // or animation restarts.
    pane.setFindBarVisible(false)
    #expect(!pane.isFindBarVisible)
    pane.setFindBarVisible(true)
    pane.setFindBarVisible(true)
    #expect(pane.isFindBarVisible)
  }

  @Test("setURLBarPeek(true) on hidden enters peek")
  func peekFromHidden() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    #expect(pane.urlBarHoverState == .hidden)
    pane.setURLBarPeek(true)
    #expect(pane.urlBarHoverState == .peek)
    #expect(pane.isURLBarVisible)
    pane.setURLBarPeek(false)
    #expect(pane.urlBarHoverState == .hidden)
    #expect(!pane.isURLBarVisible)
  }

  @Test("setURLBarPeek(true) is a no-op while pinned")
  func peekTrueIsNoOpWhilePinned() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    pane.setURLBarVisible(true)
    #expect(pane.urlBarHoverState == .pinned)
    pane.setURLBarPeek(true)
    // Pinned wins: peek must not downgrade a globally-toggled bar.
    #expect(pane.urlBarHoverState == .pinned)
  }

  @Test("setURLBarPeek(false) is a no-op while pinned")
  func peekFalseIsNoOpWhilePinned() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    pane.setURLBarVisible(true)
    pane.setURLBarPeek(false)
    // Releasing peek must not collapse a pinned bar — that's owned
    // by `setURLBarVisible(_:)`.
    #expect(pane.urlBarHoverState == .pinned)
  }

  @Test("setURLBarVisible(true) overrides an active peek")
  func visibleOverridesPeek() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    pane.setURLBarPeek(true)
    #expect(pane.urlBarHoverState == .peek)
    pane.setURLBarVisible(true)
    // Global toggle takes over — peek session ends, the bar is now
    // pinned alongside every other pane.
    #expect(pane.urlBarHoverState == .pinned)
  }

  @Test("isSuspendExempt defaults to false and is independently mutable")
  func suspendExemptDefaultAndToggle() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    #expect(!pane.isSuspendExempt)
    pane.isSuspendExempt = true
    #expect(pane.isSuspendExempt)
    pane.isSuspendExempt = false
    #expect(!pane.isSuspendExempt)
  }
}
