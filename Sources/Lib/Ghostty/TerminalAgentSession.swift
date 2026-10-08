import Darwin
import Foundation

/// A coding agent's conversation running in a terminal pane, announced by
/// the agent's own lifecycle hooks through `e05 agent-hook`. Persisted with
/// the pane so a restore can reopen the conversation instead of leaving a
/// bare prompt where it was.
public struct TerminalAgentSession: Codable, Sendable, Equatable {
  public enum Agent: String, Sendable {
    case claude
  }

  /// Kept as the raw name rather than `Agent`: a session.json written by a
  /// build that knows more agents must still decode here — a closed enum
  /// would fail the whole session, not just this pane's resume.
  public let agent: String
  public let sessionID: String

  /// Rejects anything but a known agent and a UUID: the id is typed into
  /// the pane's shell on restore, and it arrives from a hook's stdin,
  /// which any process in the pane can write.
  public init?(agent: String, sessionID: String) {
    guard Agent(rawValue: agent) != nil, UUID(uuidString: sessionID) != nil else {
      return nil
    }
    self.agent = agent
    self.sessionID = sessionID
  }

  /// The command line that reopens the conversation. Re-checks both
  /// fields because a decoded value never went through `init?` —
  /// session.json is a file on disk like any other.
  public var resumeCommand: String? {
    guard let kind = Agent(rawValue: agent), UUID(uuidString: sessionID) != nil else {
      return nil
    }
    switch kind {
    case .claude: return "claude --resume \(sessionID)"
    }
  }
}

/// The agent sessions one pane's hooks have started and not yet ended,
/// keyed by the agent's process so a restore can tell which of them is
/// still running and which is the one the user is looking at.
struct TerminalAgentTracker {
  enum Event: String {
    case start, end
  }

  private struct Entry {
    let pid: pid_t
    let session: TerminalAgentSession
  }

  /// In start order, so the newest wins when more than one is eligible
  /// (an agent suspended with ^Z while a second one runs).
  private var entries: [Entry] = []

  /// One process holds one conversation at a time: `/clear` and `/resume`
  /// end the old one and start the new one from the same process, and the
  /// two hooks are separate processes whose replies can land in either
  /// order. Replacing by pid and ending only on a matching id keeps the
  /// newer session whichever arrives first.
  mutating func record(_ event: Event, session: TerminalAgentSession, pid: pid_t) {
    switch event {
    case .start:
      entries.removeAll { $0.pid == pid }
      entries.append(Entry(pid: pid, session: session))
    case .end:
      entries.removeAll { $0.pid == pid && $0.session.sessionID == session.sessionID }
    }
  }

  mutating func reset() {
    entries.removeAll()
  }

  /// The session to reopen: the newest one whose process is still a live
  /// descendant of `root`.
  ///
  /// Liveness and descent are one check — `parent` returns nil for a pid
  /// that no longer exists — and it catches what the hooks cannot: an
  /// agent killed without running its end hook, or a pid reused since by
  /// something outside this app. LIMITATION: a pid reused by a process in
  /// another pane of this app still passes; rooting the walk at the
  /// pane's own shell would need the shell's pid, which libghostty does
  /// not expose.
  ///
  /// An agent started underneath another recorded agent is skipped. An
  /// agent's own tools can launch a headless run of the same agent, which
  /// inherits the pane's environment and reports in as this pane; the
  /// conversation on screen is the outer one.
  func resumable(root: pid_t, parent: (pid_t) -> pid_t?) -> TerminalAgentSession? {
    let recorded = Set(entries.map(\.pid))
    for entry in entries.reversed() {
      guard let ancestors = Self.ancestors(of: entry.pid, upTo: root, parent: parent),
        ancestors.isDisjoint(with: recorded)
      else { continue }
      return entry.session
    }
    return nil
  }

  /// The pids strictly between `pid` and `root`, or nil when `root` is
  /// never reached. The bound only guards against a cycle in a snapshot
  /// taken while processes come and go; real trees here are a few deep.
  private static func ancestors(
    of pid: pid_t, upTo root: pid_t, parent: (pid_t) -> pid_t?
  ) -> Set<pid_t>? {
    var found: Set<pid_t> = []
    guard var current = parent(pid) else { return nil }
    for _ in 0..<64 {
      if current == root { return found }
      guard current > 1, let next = parent(current) else { return nil }
      found.insert(current)
      current = next
    }
    return nil
  }

  /// Parent of a live process, or nil once it has exited.
  static func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    // A pid that does not exist is not an error to sysctl: it succeeds
    // and reports zero bytes.
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
      return nil
    }
    return info.kp_eproc.e_ppid
  }
}
