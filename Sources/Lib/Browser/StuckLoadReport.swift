import Foundation

/// One step a browser pane's main frame went through, kept so a
/// navigation that never arrives can be read back as how far it got.
struct NavigationEvent {
  let at: Date
  let text: String
}

/// A browser pane's state at the moment a navigation stopped making
/// progress, written out so the incident can be read after the fact.
///
/// What it is for is telling the ways a pane gets stuck apart, since
/// they look the same on screen — a spinner over a page that still
/// scrolls. The events say how far the navigation got (asked for,
/// allowed, answered, never committed); the processes say whether the
/// web content process is still answering WebKit and whether a new one
/// was launched for the navigation and never took over.
///
/// A `nil` probe means the private WebKit property behind it is gone,
/// which reads differently from a process that is simply not running.
struct StuckLoadReport {
  var capturedAt: Date
  var appVersion: String
  var systemVersion: String
  var webKitVersion: String
  var paneTag: String
  var webViewAge: TimeInterval
  var commits: Int
  var pendingFor: TimeInterval
  var pendingURL: String
  var committedURL: String
  var estimatedProgress: Double
  var webProcess: Int32?
  var webProcessResponsive: Bool?
  var webProcessFootprint: UInt64?
  var provisionalWebProcess: Int32?
  var popupsOpen: Bool
  var events: [NavigationEvent]

  func render() -> String {
    var lines = [
      "e05 stuck load report",
      "captured: \(Date.ISO8601FormatStyle(timeZone: .current).format(capturedAt))",
      "e05 \(appVersion) / \(systemVersion) / WebKit \(webKitVersion)",
      "",
      "pane \(paneTag)",
      "  web view age: \(Self.seconds(webViewAge)), \(commits) commits",
      "  pending navigation: \(Self.seconds(pendingFor)), progress "
        + String(format: "%.2f", estimatedProgress),
      "  pending url: \(pendingURL)",
      "  committed url: \(committedURL)",
      "  web process: \(Self.process(webProcess))"
        + ", responsive \(Self.flag(webProcessResponsive))"
        + ", footprint \(webProcessFootprint.map { "\($0 / 1_048_576) MB" } ?? "unknown")",
      "  provisional web process: \(Self.process(provisionalWebProcess))",
      "  popups open: \(Self.flag(popupsOpen))",
      "",
      "navigation events, oldest first (seconds before capture):",
    ]
    for event in events {
      let offset = String(format: "%9.1f", -capturedAt.timeIntervalSince(event.at))
      lines.append("  \(offset)  \(event.text)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Replace the report at `url`, readable by this user only: it names
  /// the pages the pane was on.
  func write(to url: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try render().write(to: url, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// A URL as the report and the logs show it: without the credentials,
  /// query and fragment that sign-in codes and session tokens travel in,
  /// without the payload of a URL that has no host (`data:`, `blob:`),
  /// and not at all for a private pane.
  static func describe(_ url: URL?, isPrivate: Bool) -> String {
    guard let url else { return "none" }
    if isPrivate { return "<private>" }
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "<unparsable>"
    }
    if parts.host == nil, !url.isFileURL { return "\(parts.scheme ?? "<no scheme>"):" }
    parts.user = nil
    parts.password = nil
    parts.query = nil
    parts.fragment = nil
    return parts.string ?? "<unparsable>"
  }

  private static func process(_ pid: Int32?) -> String {
    guard let pid else { return "unavailable" }
    return pid == 0 ? "none" : "pid \(pid)"
  }

  private static func flag(_ value: Bool?) -> String {
    guard let value else { return "unavailable" }
    return value ? "yes" : "no"
  }

  private static func seconds(_ interval: TimeInterval) -> String {
    String(format: "%.0fs", interval)
  }
}
