import Foundation

/// One OSC 7501 report: a program telling the terminal what it is doing.
/// Specification: https://www.superlogical.com/rex/docs/build/program-status
///
/// libghostty has already validated the report against the
/// specification's grammar and size limits, so this only reads it.
struct ProgramStatusReport: Equatable {
  enum State: String {
    case idle, working, done, blocked, error, clear
  }

  enum Kind: String {
    case permission, question, auth
  }

  let state: State
  /// Hierarchical, `/`-separated; empty for the program's root record.
  let id: String
  /// What a blocked program needs from the user.
  let kind: Kind?
  /// A stable machine-readable name, such as `claude-code`.
  let app: String?
  let title: String?
  /// One line saying why; untrusted text from the program.
  let message: String?

  /// Read the report body, everything after `7501;`. `nil` when it has
  /// no state this version knows.
  init?(body: String) {
    // Later keys win, as the specification says for repeats.
    var values: [Substring: Substring] = [:]
    for pair in body.split(separator: ":") {
      guard let eq = pair.firstIndex(of: "=") else { continue }
      values[pair[..<eq]] = pair[pair.index(after: eq)...]
    }
    guard let state = values["state"].flatMap({ State(rawValue: String($0)) }) else {
      return nil
    }
    self.state = state
    id = values["id"].map(String.init) ?? ""
    kind = state == .blocked ? values["kind"].flatMap { Kind(rawValue: String($0)) } : nil
    app = values["app"].map(String.init)
    title = values["title"].flatMap(Self.decode)
    message = values["msg"].flatMap(Self.decode)
  }

  /// Padding is optional in the specification, and Foundation's
  /// decoder insists on it.
  private static func decode(_ base64: Substring) -> String? {
    let padded = String(base64) + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: padded).flatMap { String(data: $0, encoding: .utf8) }
  }
}

/// The records one pane's programs have reported, kept the way the
/// specification's lifetime rules say. libghostty keeps none itself.
struct ProgramStatusRecords: Equatable {
  private(set) var records: [String: ProgramStatusReport] = [:]

  /// A report replaces its id's record whole; `clear` removes the id
  /// and everything beneath it, or every record when it names no id.
  /// An idle record is not kept: nothing shows it, and a pane running
  /// many short-lived programs would otherwise collect one per id.
  mutating func apply(_ report: ProgramStatusReport) {
    switch report.state {
    case .clear: break
    case .idle:
      records[report.id] = nil
      return
    default:
      records[report.id] = report
      return
    }
    if report.id.isEmpty {
      records.removeAll()
    } else {
      records = records.filter { id, _ in id != report.id && !id.hasPrefix(report.id + "/") }
    }
  }

  /// The program in the foreground returned to the shell. The
  /// specification drops working and blocked records when a new prompt
  /// starts; a command finishing is the closest thing libghostty tells
  /// the embedder. LIMITATION: a shell without integration reports no
  /// command finishing, so such records stay until the pane closes.
  mutating func commandFinished() {
    records = records.filter { $0.value.state != .working && $0.value.state != .blocked }
  }

  /// The user looked at the pane, so finished and failed work is no
  /// longer news.
  mutating func seen() {
    records = records.filter { $0.value.state != .done && $0.value.state != .error }
  }

  /// The record that speaks for the pane: the one most in need of the
  /// user. `nil` when nothing worth showing is recorded.
  var summary: ProgramStatusReport? { Self.mostUrgent(Array(records.values)) }

  /// The most urgent of several panes' statuses that an indicator draws.
  /// Working is left out: it is each pane's own loading ring, and would
  /// otherwise hide a finished or failed pane beside it.
  static func mostShown(_ reports: [ProgramStatusReport?]) -> ProgramStatusReport? {
    mostUrgent(reports.filter { $0?.state != .working })
  }

  /// The one most in need of the user; among equals, the lowest id,
  /// which puts a program's root record (it has none) first.
  static func mostUrgent(_ reports: [ProgramStatusReport?]) -> ProgramStatusReport? {
    reports.compactMap { $0 }
      .max {
        Self.urgency($0) < Self.urgency($1)
          || (Self.urgency($0) == Self.urgency($1) && $0.id > $1.id)
      }
  }

  private static func urgency(_ report: ProgramStatusReport) -> Int {
    switch report.state {
    case .blocked: 4
    case .error: 3
    case .working: 2
    case .done: 1
    case .idle, .clear: 0
    }
  }
}
