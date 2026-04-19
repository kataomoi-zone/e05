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
}
