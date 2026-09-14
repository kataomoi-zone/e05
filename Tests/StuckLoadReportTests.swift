import AppKit
import Foundation
import Testing
import WebKit

@testable import E05Lib

@Suite("Stuck load report")
struct StuckLoadReportTests {
  let capturedAt = Date(timeIntervalSince1970: 1_000_000)

  func report(
    webProcess: Int32? = 4321, provisional: Int32? = 0, events: [NavigationEvent] = []
  ) -> StuckLoadReport {
    StuckLoadReport(
      capturedAt: capturedAt, appVersion: "2026.0914.1 (800)",
      systemVersion: "macOS Version 26.6.2", webKitVersion: "21624",
      paneTag: "beef", webViewAge: 7200, commits: 12, pendingFor: 21,
      pendingURL: "https://example.com/next", committedURL: "https://example.com/",
      estimatedProgress: 0.1, webProcess: webProcess, webProcessResponsive: true,
      webProcessFootprint: 512 * 1_048_576, provisionalWebProcess: provisional,
      popupsOpen: false, events: events)
  }

  @Test("a URL loses its query and fragment, where tokens travel")
  func urlDropsQueryAndFragment() {
    let url = URL(string: "https://example.com/callback?code=secret#state=x")!
    #expect(StuckLoadReport.describe(url, isPrivate: false) == "https://example.com/callback")
  }

  @Test("credentials in a URL are not shown")
  func urlDropsCredentials() {
    let url = URL(string: "https://admin:hunter2@router.local/setup")!
    #expect(StuckLoadReport.describe(url, isPrivate: false) == "https://router.local/setup")
  }

  @Test("a URL without a host shows only its scheme, not its payload")
  func hostlessURLShowsScheme() {
    let url = URL(string: "data:text/html,<p>secret</p>")!
    #expect(StuckLoadReport.describe(url, isPrivate: false) == "data:")
    let file = URL(fileURLWithPath: "/tmp/page.html")
    #expect(StuckLoadReport.describe(file, isPrivate: false) == "file:///tmp/page.html")
  }

  @Test("a private pane's URL is not shown at all")
  func privateURLHidden() {
    let url = URL(string: "https://example.com/")!
    #expect(StuckLoadReport.describe(url, isPrivate: true) == "<private>")
    #expect(StuckLoadReport.describe(nil, isPrivate: false) == "none")
  }

  @Test("events read oldest first, as seconds before the capture")
  func eventsRelativeToCapture() throws {
    let text = report(events: [
      NavigationEvent(at: capturedAt.addingTimeInterval(-21.5), text: "policy link -> allow"),
      NavigationEvent(at: capturedAt.addingTimeInterval(-21.4), text: "provisional start"),
    ]).render()
    let policy = try #require(text.range(of: "-21.5  policy link -> allow"))
    let start = try #require(text.range(of: "-21.4  provisional start"))
    #expect(policy.lowerBound < start.lowerBound)
  }

  @Test("a missing private property reads differently from a process not running")
  func unavailableVersusNone() {
    let text = report(webProcess: nil, provisional: 0).render()
    #expect(text.contains("web process: unavailable"))
    #expect(text.contains("provisional web process: none"))
    #expect(report().render().contains("web process: pid 4321"))
  }
}

@Suite("Stuck load reporting in a pane")
@MainActor
struct StuckLoadPaneTests {
  let now = BrowserPaneView.uptime

  func temporaryReport() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("stuck-load-report.txt")
  }

  /// The report leans on private WebKit properties. If a WebKit update
  /// renames one, the report still renders but says "unavailable" — this
  /// is where that shows up first.
  @Test("the private WebKit properties the report reads are still there")
  func privatePropertiesPresent() {
    let pane = BrowserPaneView(frame: .zero)
    #expect(pane.webProcessIdentifier != nil)
    #expect(pane.webProcessIsResponsive != nil)
    #expect(pane.provisionalWebProcessIdentifier != nil)
  }

  /// App shortcuts bypass the page only while this is true, so a page
  /// that answers must never read as unresponsive.
  @Test("a web view whose process answers is not taken for unresponsive")
  func answeringProcessIsNotUnresponsive() {
    let pane = BrowserPaneView(frame: .zero)
    #expect(BrowserPaneView.webProcessIsResponsive(pane.webView) != false)
  }

  @Test("a running process's memory footprint can be read")
  func footprintOfRunningProcess() {
    #expect((BrowserPaneView.physicalFootprint(of: getpid()) ?? 0) > 1_048_576)
    #expect(BrowserPaneView.physicalFootprint(of: 0) == nil)
  }

  /// A moment far enough back that a navigation pending since then is due.
  var overdue: TimeInterval { now - BrowserPaneView.stuckNavigationThreshold - 1 }

  func reported(_ pane: BrowserPaneView, at time: TimeInterval? = nil) -> Bool {
    let destination = temporaryReport()
    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
    pane.reportStuckNavigationIfDue(now: time ?? now, destination: destination)
    return FileManager.default.fileExists(atPath: destination.path)
  }

  @Test("a navigation pending past the threshold is reported once, readable by this user only")
  func reportsOnce() throws {
    let pane = BrowserPaneView(frame: .zero)
    let destination = temporaryReport()
    defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
    var toasts = 0
    pane.onStuckLoad = { toasts += 1 }
    pane.beginPendingNavigation(now: overdue)

    pane.reportStuckNavigationIfDue(now: now, destination: destination)
    let mode = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o600)
    #expect(!reported(pane))
    #expect(toasts == 1)
  }

  @Test("a navigation still inside the threshold is not reported")
  func notYetDue() {
    let pane = BrowserPaneView(frame: .zero)
    pane.beginPendingNavigation(now: now - BrowserPaneView.stuckNavigationThreshold + 1)
    #expect(!reported(pane))
  }

  @Test("the provisional start of a load starts the clock")
  func provisionalStartBegins() {
    let pane = BrowserPaneView(frame: .zero)
    pane.webView(pane.webView, didStartProvisionalNavigation: nil)
    #expect(
      reported(pane, at: BrowserPaneView.uptime + BrowserPaneView.stuckNavigationThreshold + 1))
  }

  /// A web content process that never picks a reload up asks no policy
  /// question and starts no load, so the request itself has to count.
  @Test("a reload e05 asks for starts the clock before WebKit answers")
  func requestedReloadBegins() {
    let pane = BrowserPaneView(frame: .zero)
    pane.reload()
    #expect(
      reported(pane, at: BrowserPaneView.uptime + BrowserPaneView.stuckNavigationThreshold + 1))
  }

  /// Going back with nothing to go back to starts no navigation, and on a
  /// page still loading an image nothing would ever end the clock.
  @Test("going back or forward with no history starts no clock")
  func noHistoryStartsNoClock() {
    let pane = BrowserPaneView(frame: .zero)
    pane.goBack()
    pane.goForward()
    #expect(
      !reported(pane, at: BrowserPaneView.uptime + BrowserPaneView.stuckNavigationThreshold + 1))
  }

  @Test("a report that could not be written raises no toast")
  func failedWriteRaisesNoToast() throws {
    let pane = BrowserPaneView(frame: .zero)
    var toasts = 0
    pane.onStuckLoad = { toasts += 1 }
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: blocker)
    defer { try? FileManager.default.removeItem(at: blocker) }
    pane.beginPendingNavigation(now: overdue)
    // A file where the report's directory should be.
    pane.reportStuckNavigationIfDue(
      now: now, destination: blocker.appendingPathComponent("stuck-load-report.txt"))
    #expect(toasts == 0)
  }

  /// A redirect hop and a click on top of a stuck page arrive while the
  /// pane is loading; restarting the clock for each would keep a user
  /// who retries from ever reaching the threshold.
  @Test("a navigation begun while loading keeps the clock already running")
  func loadingKeepsClock() {
    let pane = BrowserPaneView(frame: .zero)
    pane.beginPendingNavigation(now: overdue, loading: false)
    pane.beginPendingNavigation(now: now, loading: true)
    #expect(reported(pane))
  }

  @Test("a navigation begun on a settled pane starts a fresh clock and a fresh report")
  func settledPaneRestartsClock() {
    let pane = BrowserPaneView(frame: .zero)
    pane.beginPendingNavigation(now: overdue, loading: false)
    #expect(reported(pane))
    pane.beginPendingNavigation(now: now, loading: false)
    #expect(!reported(pane))
    #expect(reported(pane, at: now + BrowserPaneView.stuckNavigationThreshold))
  }

  @Test("a commit ends the pending navigation")
  func commitClearsPending() {
    let pane = BrowserPaneView(frame: .zero)
    pane.beginPendingNavigation(now: overdue)
    pane.webView(pane.webView, didCommit: nil)
    #expect(!reported(pane))
  }

  /// A fragment link passes the policy check and never commits.
  @Test("a fragment link or a history move within the page ends the pending navigation")
  func sameDocumentClearsPending() {
    for type in [0, 3] {
      let pane = BrowserPaneView(frame: .zero)
      pane.beginPendingNavigation(now: overdue)
      pane.webViewDidSameDocumentNavigation(pane.webView, navigation: nil, type: type)
      #expect(!reported(pane), "type \(type)")
    }
  }

  /// A page rewriting its own URL as it scrolls must not keep resetting
  /// the clock of a navigation that is really stuck.
  @Test("a pushState or replaceState from the page leaves the pending navigation alone")
  func sessionStateKeepsPending() {
    for type in [1, 2] {
      let pane = BrowserPaneView(frame: .zero)
      pane.beginPendingNavigation(now: overdue)
      pane.webViewDidSameDocumentNavigation(pane.webView, navigation: nil, type: type)
      #expect(reported(pane), "type \(type)")
      #expect(pane.navigationEvents.last?.text != "same-document navigation")
    }
  }

  @Test("a web content process termination ends the pending navigation")
  func terminationClearsPending() {
    let pane = BrowserPaneView(frame: .zero)
    pane.beginPendingNavigation(now: overdue)
    pane.webViewWebContentProcessDidTerminate(pane.webView)
    #expect(!reported(pane))
  }

  /// Clicking or reloading on top of a stuck navigation cancels the old
  /// one after the new one has been allowed, so the cancellation must
  /// not end the timing the new one continues.
  @Test("a replaced navigation's cancellation keeps the clock running")
  func cancellationKeepsPending() {
    let pane = BrowserPaneView(frame: .zero)
    pane.beginPendingNavigation(now: overdue)
    pane.webView(
      pane.webView, didFailProvisionalNavigation: nil,
      withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
    #expect(reported(pane))
  }

  @Test("a provisional failure ends the pending navigation")
  func failureClearsPending() {
    let pane = BrowserPaneView(frame: .zero)
    pane.beginPendingNavigation(now: overdue)
    pane.webView(
      pane.webView, didFailProvisionalNavigation: nil,
      withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
    #expect(!reported(pane))
  }

  @Test("a private pane writes nothing to disk")
  func privatePaneWritesNothing() {
    let pane = BrowserPaneView(
      frame: .zero, extensionContext: nil, dataStore: .nonPersistent())
    var toasts = 0
    pane.onStuckLoad = { toasts += 1 }
    pane.beginPendingNavigation(now: overdue)
    #expect(!reported(pane))
    #expect(toasts == 0)
  }

  @Test("the event list keeps the newest steps")
  func eventsCapped() {
    let pane = BrowserPaneView(frame: .zero)
    for i in 0..<(BrowserPaneView.navigationEventLimit + 10) {
      pane.noteNavigation("step \(i)")
    }
    #expect(pane.navigationEvents.count == BrowserPaneView.navigationEventLimit)
    #expect(pane.navigationEvents.last?.text == "step \(BrowserPaneView.navigationEventLimit + 9)")
  }
}
