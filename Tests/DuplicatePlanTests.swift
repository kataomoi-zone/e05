import Foundation
import Testing

@testable import E05Lib

/// `PaneContainerViewController.duplicatePlan` is the per-kind decision
/// behind Duplicate Pane (and the `canDuplicateFocusedPane` gate). Browser
/// and terminal duplicates need loaded views, so those branches stay
/// integration-tested; these pin the address-only branches plus the
/// "browser without a URL can't be duplicated" rule that the command's
/// validation depends on.
@Suite("PaneContainerViewController.duplicatePlan")
@MainActor
struct DuplicatePlanTests {
  @Test("no source yields no plan")
  func nilSource() {
    #expect(PaneContainerViewController.duplicatePlan(for: nil) == nil)
  }

  @Test("a finder pane duplicates to its own finder address")
  func finderSource() {
    let source = PaneModel(address: .finder(path: "/tmp"), ghosttyApp: nil)
    let plan = PaneContainerViewController.duplicatePlan(for: source)
    #expect(plan?.address.kind == .finder)
    #expect(plan?.address == source.address)
  }

  @Test("a start pane duplicates to another start page")
  func startSource() {
    let source = PaneModel(address: .start, ghosttyApp: nil)
    #expect(PaneContainerViewController.duplicatePlan(for: source)?.address.kind == .start)
  }

  @Test("a blank browser with no URL can't be duplicated")
  func blankBrowserWithoutURL() {
    let source = PaneModel(address: .blankBrowser, ghosttyApp: nil)
    #expect(PaneContainerViewController.duplicatePlan(for: source) == nil)
  }
}
