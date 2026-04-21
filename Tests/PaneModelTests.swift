import AppKit
import Testing

@testable import E05Lib

@Suite("PaneModel")
@MainActor
struct PaneModelTests {
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
    #expect(pane.findBar.isHidden)
  }

  @Test("setFindBarVisible toggles isHidden alongside the flag")
  func setFindBarVisibleTogglesHidden() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    pane.setFindBarVisible(true)
    #expect(pane.isFindBarVisible)
    #expect(!pane.findBar.isHidden)
    pane.setFindBarVisible(false)
    #expect(!pane.isFindBarVisible)
    #expect(pane.findBar.isHidden)
  }

  @Test("setFindBarVisible with the same value is a no-op")
  func setFindBarVisibleIdempotent() {
    let pane = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    // Re-applying the default must not drive spurious constraint
    // churn or hidden-state flips.
    pane.setFindBarVisible(false)
    #expect(!pane.isFindBarVisible)
    pane.setFindBarVisible(true)
    pane.setFindBarVisible(true)
    #expect(pane.isFindBarVisible)
    #expect(!pane.findBar.isHidden)
  }
}
