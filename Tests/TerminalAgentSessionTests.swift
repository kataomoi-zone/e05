import Darwin
import Foundation
import Testing

@testable import E05Lib

private let idA = "11111111-1111-4111-8111-111111111111"
private let idB = "22222222-2222-4222-8222-222222222222"

private func session(_ id: String) -> TerminalAgentSession {
  TerminalAgentSession(agent: "claude", sessionID: id)!
}

/// A process tree as a child → parent table; anything absent has exited.
/// `root` stands for the app, `1` for launchd.
private let root: pid_t = 100
private func tree(_ edges: [pid_t: pid_t]) -> (pid_t) -> pid_t? {
  { edges[$0] }
}

@Suite("Terminal agent session")
struct TerminalAgentSessionTests {
  @Test("only a UUID is accepted as a session id")
  func validatesSessionID() {
    #expect(TerminalAgentSession(agent: "claude", sessionID: idA) != nil)
    #expect(TerminalAgentSession(agent: "claude", sessionID: "abc") == nil)
    // The id is typed into a shell on restore.
    #expect(TerminalAgentSession(agent: "claude", sessionID: "\(idA); rm -rf ~") == nil)
    #expect(TerminalAgentSession(agent: "codex", sessionID: idA) == nil)
  }

  @Test("the resume command names the session")
  func resumeCommand() {
    #expect(session(idA).resumeCommand == "claude --resume \(idA)")
  }

  /// A decoded value never passed through `init?`.
  @Test("a session decoded with a bad id yields no command")
  func decodedBadIDHasNoCommand() throws {
    let json = Data(#"{"agent":"claude","sessionID":"x; rm -rf ~"}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalAgentSession.self, from: json)
    #expect(decoded.resumeCommand == nil)
  }

  /// Written by a build that knows more agents: decoding must not fail,
  /// or the whole session.json goes with it.
  @Test("a session decoded with an unknown agent yields no command")
  func decodedUnknownAgentHasNoCommand() throws {
    let json = Data(#"{"agent":"codex","sessionID":"\#(idA)"}"#.utf8)
    let decoded = try JSONDecoder().decode(TerminalAgentSession.self, from: json)
    #expect(decoded.resumeCommand == nil)
  }
}

@Suite("Terminal agent tracker")
struct TerminalAgentTrackerTests {
  // shell 200 under the app, agent 300 under the shell.
  let live = tree([200: root, 300: 200])

  @Test("a started session in a live agent is resumable")
  func startedIsResumable() {
    var tracker = TerminalAgentTracker()
    tracker.record(.start, session: session(idA), pid: 300)
    #expect(tracker.resumable(root: root, parent: live) == session(idA))
  }

  @Test("an ended session is not resumable")
  func endedIsGone() {
    var tracker = TerminalAgentTracker()
    tracker.record(.start, session: session(idA), pid: 300)
    tracker.record(.end, session: session(idA), pid: 300)
    #expect(tracker.resumable(root: root, parent: live) == nil)
  }

  /// `/clear` ends one session and starts another from the same process;
  /// the two hooks race, so either order must leave the new one.
  @Test("a clear keeps the new session whichever hook lands first")
  func clearInEitherOrder() {
    var endFirst = TerminalAgentTracker()
    endFirst.record(.start, session: session(idA), pid: 300)
    endFirst.record(.end, session: session(idA), pid: 300)
    endFirst.record(.start, session: session(idB), pid: 300)
    #expect(endFirst.resumable(root: root, parent: live) == session(idB))

    var startFirst = TerminalAgentTracker()
    startFirst.record(.start, session: session(idA), pid: 300)
    startFirst.record(.start, session: session(idB), pid: 300)
    startFirst.record(.end, session: session(idA), pid: 300)
    #expect(startFirst.resumable(root: root, parent: live) == session(idB))
  }

  /// Killed without its end hook running.
  @Test("a session whose process exited is not resumable")
  func exitedProcess() {
    var tracker = TerminalAgentTracker()
    tracker.record(.start, session: session(idA), pid: 300)
    #expect(tracker.resumable(root: root, parent: tree([200: root])) == nil)
  }

  /// A pid reused by something outside the app after the agent died, or
  /// a report from an agent the pane's shell does not own (inside a tmux
  /// server, which daemonizes away from the app).
  @Test("a process outside the app is not resumable")
  func outsideTheApp() {
    var tracker = TerminalAgentTracker()
    tracker.record(.start, session: session(idA), pid: 300)
    #expect(tracker.resumable(root: root, parent: tree([300: 1])) == nil)
  }

  /// The agent's own tool ran a headless agent, which inherited the pane.
  @Test("an agent started under another recorded agent is skipped")
  func nestedAgentSkipped() {
    var tracker = TerminalAgentTracker()
    tracker.record(.start, session: session(idA), pid: 300)
    tracker.record(.start, session: session(idB), pid: 500)
    // 500 runs in a tool shell 400 that the outer agent 300 spawned.
    let nested = tree([200: root, 300: 200, 400: 300, 500: 400])
    #expect(tracker.resumable(root: root, parent: nested) == session(idA))
  }

  @Test("the newest of two eligible sessions wins")
  func newestWins() {
    var tracker = TerminalAgentTracker()
    tracker.record(.start, session: session(idA), pid: 300)
    tracker.record(.start, session: session(idB), pid: 301)
    let both = tree([200: root, 300: 200, 301: 200])
    #expect(tracker.resumable(root: root, parent: both) == session(idB))
  }

  @Test("a cycle in the process table ends the walk")
  func cycleTerminates() {
    var tracker = TerminalAgentTracker()
    tracker.record(.start, session: session(idA), pid: 300)
    #expect(tracker.resumable(root: root, parent: tree([300: 400, 400: 300])) == nil)
  }

  @Test("the live process table reports this process's parent")
  func liveParent() {
    #expect(TerminalAgentTracker.parentPID(of: getpid()) == getppid())
    // pid_t max is never allocated.
    #expect(TerminalAgentTracker.parentPID(of: pid_t.max) == nil)
  }
}
