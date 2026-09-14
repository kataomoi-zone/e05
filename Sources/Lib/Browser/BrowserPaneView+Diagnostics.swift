import AppKit
import Darwin
import WebKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "BrowserPaneView")

/// Tracing for a navigation that starts and never arrives: the page on
/// screen keeps scrolling, the loading bar keeps moving, and a click or
/// a reload goes nowhere. Nothing here recovers the pane — it records
/// enough to tell afterwards which layer held the navigation up.
extension BrowserPaneView {
  static let navigationEventLimit = 32
  /// How long a navigation may stay pending before it is reported. Past
  /// the minute WebKit waits on a server that sends nothing before it
  /// fails the load itself, so a silent server ends in its own timeout
  /// page rather than a report; what is still pending after that is held
  /// up somewhere that never times out.
  ///
  /// LIMITATION: an upload still sending its body this long is reported
  /// the same way.
  static let stuckNavigationThreshold: TimeInterval = 75

  /// The clock pending navigations are timed on. It stands still while
  /// the Mac sleeps, so a night asleep mid-load is not counted as time the
  /// navigation spent stuck.
  static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

  func noteNavigation(_ text: String) {
    navigationEvents.append(NavigationEvent(at: Date(), text: text))
    if navigationEvents.count > Self.navigationEventLimit {
      navigationEvents.removeFirst(navigationEvents.count - Self.navigationEventLimit)
    }
  }

  func describe(_ url: URL?) -> String {
    StuckLoadReport.describe(url, isPrivate: isPrivateBrowsing)
  }

  /// A navigation e05 itself asked for. It starts the clock before
  /// WebKit is involved, so a web content process that never picks the
  /// request up still gets reported.
  func noteRequestedNavigation(_ text: String) {
    noteNavigation("requested \(text)")
    beginPendingNavigation()
  }

  /// Start timing a navigation. A pane already loading keeps the clock it
  /// has: a server redirect or a click that replaces a stuck navigation
  /// continues the wait the user is already in, rather than starting it
  /// over each time.
  func beginPendingNavigation(now: TimeInterval = uptime, loading: Bool? = nil) {
    guard pendingNavigationSince == nil || !(loading ?? webView.isLoading) else { return }
    pendingNavigationSince = now
    reportedPendingNavigation = false
  }

  /// Record a main-frame policy decision, and time the navigation it lets
  /// through. Subframes are left out: a page's ads and embeds navigate
  /// constantly and would push the steps that matter out of the capped
  /// list.
  func noteMainFramePolicy(
    for navigationAction: WKNavigationAction, policy: WKNavigationActionPolicy
  ) {
    guard navigationAction.targetFrame?.isMainFrame == true else { return }
    let verdict: String
    switch policy {
    case .allow: verdict = "allow"
    case .cancel: verdict = "cancel"
    case .download: verdict = "download"
    @unknown default: verdict = "policy \(policy.rawValue)"
    }
    noteNavigation(
      "policy \(Self.label(navigationAction.navigationType)) "
        + "\(describe(navigationAction.request.url)) -> \(verdict)")
    if policy == .allow { beginPendingNavigation() }
  }

  /// The process state that separates one kind of stuck from another,
  /// on one line for the watchdog log.
  var processSummary: String {
    let pending = pendingNavigationSince.map { String(format: "%.0fs", Self.uptime - $0) }
    return "pending=\(pending ?? "none") "
      + "wpid=\(webProcessIdentifier.map(String.init) ?? "?") "
      + "responsive=\(webProcessIsResponsive.map(String.init) ?? "?") "
      + "provisional=\(provisionalWebProcessIdentifier.map(String.init) ?? "?") "
      + "last=\"\(navigationEvents.last?.text ?? "none")\""
  }

  /// Write the report once the pending navigation has gone past
  /// ``stuckNavigationThreshold``. Driven by the loading watchdog's tick,
  /// so it fires within one watchdog interval after the threshold.
  ///
  /// LIMITATION: one file, overwritten by the next stuck navigation. The
  /// error line logged alongside carries the same process summary and
  /// stays in the log archive for each incident.
  func reportStuckNavigationIfDue(
    now: TimeInterval = uptime,
    destination: URL = E05Paths.default.dataFile(E05Filenames.stuckLoadReport)
  ) {
    guard let since = pendingNavigationSince, !reportedPendingNavigation,
      now - since >= Self.stuckNavigationThreshold
    else { return }
    reportedPendingNavigation = true
    // A report on disk names the pages a private workspace exists to
    // leave no trace of, so a private pane only logs.
    var outcome = "no report written for a private pane"
    var written = false
    if !isPrivateBrowsing {
      do {
        try makeStuckLoadReport(pendingFor: now - since).write(to: destination)
        outcome = "report written to \(destination.path)"
        written = true
      } catch {
        outcome = "report write failed: \(error.localizedDescription)"
      }
    }
    logger.error(
      "[nav/stuck \(self.logTag, privacy: .public)] navigation pending for \(Int(now - since), privacy: .public)s, \(outcome, privacy: .public) \(self.processSummary, privacy: .public)"
    )
    if written { onStuckLoad?() }
  }

  func makeStuckLoadReport(pendingFor: TimeInterval) -> StuckLoadReport {
    let now = Date()
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "unknown"
    let webKit = Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String
    let pid = webProcessIdentifier
    return StuckLoadReport(
      capturedAt: now,
      appVersion: "\(version) (\(build))",
      systemVersion: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
      webKitVersion: webKit ?? "unknown",
      paneTag: logTag,
      webViewAge: now.timeIntervalSince(webViewAttachedAt),
      commits: commitsSinceAttach,
      pendingFor: pendingFor,
      // While a navigation is provisional, `url` is where it is headed;
      // the back/forward list's current item is what is still on screen.
      pendingURL: describe(webView.url),
      committedURL: describe(webView.backForwardList.currentItem?.url),
      estimatedProgress: webView.estimatedProgress,
      webProcess: pid,
      webProcessResponsive: webProcessIsResponsive,
      webProcessFootprint: pid.flatMap(Self.physicalFootprint(of:)),
      provisionalWebProcess: provisionalWebProcessIdentifier,
      popupsOpen: hasOpenPopups,
      events: navigationEvents)
  }

  // MARK: - WebKit private state

  // Read through `responds(to:)` first: `value(forKey:)` on a key that
  // is gone raises instead of returning nil, and these are private.

  var webProcessIdentifier: Int32? {
    Self.privateValue(of: webView, "_webProcessIdentifier")?.int32Value
  }

  /// Whether WebKit's own responsiveness timer last heard back from the
  /// web content process. Scrolling runs off that process's main thread,
  /// so a page that scrolls says nothing about this.
  var webProcessIsResponsive: Bool? { Self.webProcessIsResponsive(webView) }

  static func webProcessIsResponsive(_ webView: WKWebView) -> Bool? {
    privateValue(of: webView, "_webProcessIsResponsive")?.boolValue
  }

  /// The process a cross-site navigation launches before it commits and
  /// takes over from the current one. Non-zero while that hand-over is
  /// still pending.
  var provisionalWebProcessIdentifier: Int32? {
    Self.privateValue(of: webView, "_provisionalWebProcessIdentifier")?.int32Value
  }

  static func privateValue(of object: NSObject, _ key: String) -> NSNumber? {
    guard object.responds(to: NSSelectorFromString(key)) else { return nil }
    return object.value(forKey: key) as? NSNumber
  }

  /// The figure Activity Monitor shows as a process's memory.
  static func physicalFootprint(of pid: Int32) -> UInt64? {
    guard pid > 0 else { return nil }
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
        proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
      }
    }
    return result == 0 ? usage.ri_phys_footprint : nil
  }

  private static func label(_ type: WKNavigationType) -> String {
    switch type {
    case .linkActivated: "link"
    case .formSubmitted: "form"
    case .backForward: "back/forward"
    case .reload: "reload"
    case .formResubmitted: "form resubmit"
    case .other: "other"
    @unknown default: "type \(type.rawValue)"
    }
  }

  // MARK: - WKNavigationDelegatePrivate

  /// A fragment link or a history move within the page. It passes the
  /// main-frame policy check like any navigation but never commits, so it
  /// has to end the pending time here or a page still loading an image
  /// would be reported as stuck.
  ///
  /// `pushState` / `replaceState` arrive here too (types 1 and 2), from
  /// the page already on screen and without any policy check. Left out:
  /// a page that rewrites its URL as it scrolls would otherwise keep
  /// resetting the clock of a navigation that really is stuck, and flush
  /// the steps that matter out of the capped list.
  @objc(_webView:navigation:didSameDocumentNavigation:)
  func webViewDidSameDocumentNavigation(
    _ webView: WKWebView, navigation _: WKNavigation?, type: Int
  ) {
    guard webView === self.webView, Self.endsPendingNavigation(sameDocumentType: type)
    else { return }
    noteNavigation("same-document navigation")
    pendingNavigationSince = nil
  }

  /// `_WKSameDocumentNavigationType`: anchor 0, push 1, replace 2, pop 3.
  static func endsPendingNavigation(sameDocumentType type: Int) -> Bool {
    type == 0 || type == 3
  }

  @objc(_webViewWebProcessDidBecomeUnresponsive:)
  func webViewWebProcessDidBecomeUnresponsive(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    noteNavigation("web content process unresponsive")
    logger.error(
      "[nav/unresponsive \(self.logTag, privacy: .public)] web content process stopped answering url=\(self.describe(webView.url), privacy: .public) \(self.processSummary, privacy: .public)"
    )
  }

  @objc(_webViewWebProcessDidBecomeResponsive:)
  func webViewWebProcessDidBecomeResponsive(_ webView: WKWebView) {
    guard webView === self.webView else { return }
    noteNavigation("web content process responsive again")
  }
}
