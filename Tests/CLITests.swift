import Darwin
import Foundation
import Testing

@testable import E05Lib

// Behavioural tests for the `e05` CLI that ships in
// Contents/Resources/bin. Its argument parsing and its half of the
// control-socket protocol had no test at all: the `open` shim's cases
// exercise a *stub* named e05, so everything the real binary decides —
// which path becomes which file URL, which failure becomes which exit
// code — was only ever exercised by hand.
//
// The binary is run rather than linked. SwiftPM would link it — the
// top-level declarations in an executable target are visible to a test
// that depends on it — but nothing worth asserting survives the move:
// the CLI answers by calling `exit()`, which would take the test process
// with it; it reads `CommandLine.arguments`, which belong to the test
// runner; and it finds its socket from `_NSGetExecutablePath`, which
// only points inside an `.app` when a real process runs from one.
//
// The host end is a real `ControlSocket` on a private path rather than a
// stand-in, which puts the CLI's encoder and the host's decoder under the
// same assertion — a wire format that drifted on either side fails here.

/// The `e05cli` binary SwiftPM just built. It lands beside the test
/// bundle in the same build directory, and `swift build --build-tests`
/// — what `swift test` runs — builds it, so it is present whenever
/// these tests are.
private final class BundleAnchor {}
private let cliURL =
  Bundle(for: BundleAnchor.self)
  .bundleURL
  .deletingLastPathComponent()
  .appendingPathComponent("e05cli")

// MARK: - Host

/// What the host received and what it should answer with.
@MainActor
private final class Recorder {
  var requests: [ControlSocket.Request] = []
  let reply: ControlSocket.Response

  init(reply: ControlSocket.Response) { self.reply = reply }
}

/// A live `ControlSocket` on a directory of its own, torn down after
/// `body`: the developer's running app must never be the host under
/// test.
@MainActor
private func withHost(
  replying reply: ControlSocket.Response = ControlSocket.Response(ok: true),
  _ body: (Recorder, String) async throws -> Void
) async throws {
  let dir = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: dir) }

  let recorder = Recorder(reply: reply)
  let socketPath = dir.appendingPathComponent("control.sock").path
  let socket = ControlSocket(socketPath: socketPath) { request in
    recorder.requests.append(request)
    return recorder.reply
  }
  try socket.start()
  defer { socket.stop() }

  try await body(recorder, socketPath)
}

/// A short unique directory, symlinks resolved. Short because
/// `sockaddr_un.sun_path` holds 104 bytes and the per-user temporary
/// directory already spends half of that — a UUID-named one would push
/// the socket past the limit the CLI guards against, and every case
/// would fail on a diagnostic instead of the behaviour under test.
///
/// Resolved with `realpath(3)` rather than `resolvingSymlinksInPath`:
/// Foundation's version *strips* a leading `/private` instead of
/// resolving into it, while the kernel reports the physical path for a
/// working directory — and the CLI turns that into the file URL these
/// cases assert on.
private func makeTempDirectory() throws -> URL {
  let name = String(UInt32.random(in: .min ... .max), radix: 16)
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("e05cli-\(name)")
  // Not `withIntermediateDirectories`, which would hand back a directory
  // another case is already using: 32 bits collide rarely, and cases run
  // in parallel, so the teardown of one would take the other's socket
  // out from under it. This way a collision throws where it happened.
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
  guard let resolved = realpath(dir.path, nil) else { throw POSIXError(.ENOENT) }
  defer { free(resolved) }
  return URL(fileURLWithPath: String(cString: resolved))
}

// MARK: - Running the binary

private struct CLIRun: Sendable {
  let status: Int32
  let stdout: String
  let stderr: String
}

/// Runs the CLI off the main actor. The host's handler hops to the main
/// actor and holds the connection until it returns, so a case that
/// waited for the process *on* the main actor would deadlock against
/// the very reply it is waiting for.
private func runCLI(
  _ arguments: [String],
  socketPath: String?,
  workingDirectory: URL? = nil,
  executable: URL = cliURL
) async throws -> CLIRun {
  try await Task.detached {
    // `Process` is not Sendable and nothing outside this task touches
    // this one; the watchdog below calls `terminate()`, which is safe
    // from any thread.
    nonisolated(unsafe) let process = Process()
    process.executableURL = executable
    process.arguments = arguments

    var environment = ProcessInfo.processInfo.environment
    // Assigning nil removes the key, which is the point for the
    // discovery cases: a developer who exports E05_SOCKET would
    // otherwise have them aim at their own running app.
    environment["E05_SOCKET"] = socketPath
    process.environment = environment
    if let workingDirectory { process.currentDirectoryURL = workingDirectory }

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()

    // Nothing else in the round trip has a bound of its own — not the
    // CLI's read loop, not the host's hop to the main actor, not the
    // wait below. Without this, a wedge anywhere in it sits until the ci
    // job's own ceiling and says nothing about which case hung.
    // Terminating closes the child's pipes, so the reads end too.
    let watchdog = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
    defer { watchdog.cancel() }
    // The usage text is the largest thing either stream carries, well
    // under the pipe buffer, so draining before the wait cannot block.
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return CLIRun(
      status: process.terminationStatus,
      stdout: String(decoding: outData, as: UTF8.self),
      stderr: String(decoding: errData, as: UTF8.self))
  }.value
}

/// One line per request so a case can assert the whole decoded shape —
/// op and payload together — instead of pattern-matching in every test.
@MainActor
private func described(_ request: ControlSocket.Request?) -> String {
  switch request {
  case .open(let url): "open \(url)"
  case .action(let id): "action \(id)"
  case .switchWorkspace(let index): "switch-workspace \(index)"
  case .notify(let message): "notify \(message)"
  case .invalid(let message): "invalid \(message)"
  case nil: "<nothing sent>"
  }
}

// MARK: - Arguments on the wire

@Suite("e05 CLI requests")
@MainActor
struct CLIRequestTests {
  @Test("a URL with a scheme is passed through untouched")
  func passesURLThrough() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["open", "https://example.com/a?b=c"], socketPath: socket)
      #expect(run.status == 0)
      #expect(described(host.requests.first) == "open https://example.com/a?b=c")
    }
  }

  /// The host resolves what it is handed against `PaneAddress.finder`,
  /// and its idea of "here" is not the shell's, so a bare path has to
  /// arrive absolute or it opens the wrong directory.
  @Test("a relative path is resolved against the caller's directory")
  func resolvesRelativePath() async throws {
    let cwd = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let expected = URL(fileURLWithPath: cwd.appendingPathComponent("adir").path).absoluteString

    try await withHost { host, socket in
      let run = try await runCLI(["open", "adir"], socketPath: socket, workingDirectory: cwd)
      #expect(run.status == 0)
      #expect(described(host.requests.first) == "open \(expected)")
    }
  }

  /// `~` reaches the CLI unexpanded whenever it was quoted, which is
  /// exactly how a script that builds the argument writes it. The name
  /// is one nothing owns: `URL(fileURLWithPath:)` appends a slash to a
  /// path that exists and is a directory, and the expectation would
  /// then miss on whichever machine happens to have one.
  @Test("a tilde path expands to the home directory")
  func expandsTilde() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let expected = home.appendingPathComponent(".e05-cli-probe").absoluteString
    try await withHost { host, socket in
      let run = try await runCLI(["open", "~/.e05-cli-probe"], socketPath: socket)
      #expect(run.status == 0)
      #expect(described(host.requests.first) == "open \(expected)")
    }
  }

  @Test("a path with .. is standardized before it is sent")
  func standardizesDotDot() async throws {
    let cwd = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let expected = URL(fileURLWithPath: cwd.appendingPathComponent("b").path).absoluteString

    try await withHost { host, socket in
      let run = try await runCLI(["open", "a/../b"], socketPath: socket, workingDirectory: cwd)
      #expect(run.status == 0)
      #expect(described(host.requests.first) == "open \(expected)")
    }
  }

  /// A path with a space is one argument to the CLI but several to a
  /// shell that forgot to quote; joining is what makes the two forms
  /// reach the host identically.
  @Test("notify joins its positional arguments")
  func joinsNotifyArguments() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["notify", "Hello", "world"], socketPath: socket)
      #expect(run.status == 0)
      #expect(described(host.requests.first) == "notify Hello world")
    }
  }

  @Test("action forwards the id")
  func forwardsActionID() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["action", "focus_right"], socketPath: socket)
      #expect(run.status == 0)
      #expect(described(host.requests.first) == "action focus_right")
    }
  }

  /// Sent as a JSON number, not a string: the host decodes `index` as
  /// `Int` and answers "invalid 'index': type mismatch" otherwise.
  @Test("switch-workspace forwards the index as a number")
  func forwardsWorkspaceIndex() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["switch-workspace", "3"], socketPath: socket)
      #expect(run.status == 0)
      #expect(described(host.requests.first) == "switch-workspace 3")
    }
  }
}

// MARK: - Exit codes

/// The three failure codes are the CLI's contract with a caller: a
/// shell script branches on "the host said no" (1) versus "the request
/// never made sense" (2) versus "the host is not there" (3), without
/// parsing stderr. Collapsing any two of them silently breaks that.
@Suite("e05 CLI exit codes")
@MainActor
struct CLIExitCodeTests {
  @Test("a host reply of ok=false exits 1 and repeats the message")
  func hostErrorExitsOne() async throws {
    let reply = ControlSocket.Response(ok: false, error: "no such workspace")
    try await withHost(replying: reply) { _, socket in
      let run = try await runCLI(["switch-workspace", "9"], socketPath: socket)
      #expect(run.status == 1)
      #expect(run.stderr.contains("no such workspace"))
      #expect(run.stderr.contains("e05 switch-workspace"))
    }
  }

  /// The host is not running: the message has to name the path it tried,
  /// because the path is derived rather than given and a wrong one is
  /// otherwise invisible.
  @Test("an unreachable host exits 3 and names the socket")
  func unreachableHostExitsThree() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let absent = dir.appendingPathComponent("control.sock").path

    let run = try await runCLI(["action", "focus_right"], socketPath: absent)
    #expect(run.status == 3)
    #expect(run.stderr.contains(absent))
  }

  /// `sun_path` holds 104 bytes, and `strlcpy` truncates rather than
  /// refusing — so a path over the limit that got through would have the
  /// CLI talking to whatever socket the shortened one happens to name.
  @Test("a socket path too long to fit exits 3 instead of being truncated")
  func overlongSocketPathExitsThree() async throws {
    let overlong = "/tmp/" + String(repeating: "s", count: 120) + ".sock"
    let run = try await runCLI(["action", "focus_right"], socketPath: overlong)
    #expect(run.status == 3)
    #expect(run.stderr.contains("socket path too long"))
  }

  /// Nothing is sent for a request the CLI can reject itself — an
  /// argument error must not reach the host as a half-formed op.
  @Test("a missing argument exits 2 without contacting the host")
  func missingArgumentExitsTwo() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["open"], socketPath: socket)
      #expect(run.status == 2)
      #expect(run.stderr.contains("missing argument"))
      #expect(host.requests.isEmpty)
    }
  }

  @Test("an empty notify message exits 2 without contacting the host")
  func emptyNotifyExitsTwo() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["notify"], socketPath: socket)
      #expect(run.status == 2)
      #expect(host.requests.isEmpty)
    }
  }

  @Test("a non-numeric workspace index exits 2 without contacting the host")
  func nonNumericIndexExitsTwo() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["switch-workspace", "one"], socketPath: socket)
      #expect(run.status == 2)
      #expect(host.requests.isEmpty)
    }
  }

  /// Indexes are zero-based, so a negative one is a caller bug rather
  /// than a workspace the host might grow later.
  @Test("a negative workspace index exits 2 without contacting the host")
  func negativeIndexExitsTwo() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["switch-workspace", "-1"], socketPath: socket)
      #expect(run.status == 2)
      #expect(host.requests.isEmpty)
    }
  }

  @Test("an unknown subcommand exits 2 with usage on stderr")
  func unknownSubcommandExitsTwo() async throws {
    try await withHost { host, socket in
      let run = try await runCLI(["frobnicate"], socketPath: socket)
      #expect(run.status == 2)
      #expect(run.stderr.contains("unknown subcommand 'frobnicate'"))
      #expect(run.stderr.contains("Usage: e05"))
      #expect(run.stdout.isEmpty)
      #expect(host.requests.isEmpty)
    }
  }

  @Test("no arguments at all exits 2 with usage on stderr")
  func noArgumentsExitsTwo() async throws {
    let run = try await runCLI([], socketPath: nil)
    #expect(run.status == 2)
    #expect(run.stderr.contains("Usage: e05"))
    #expect(run.stdout.isEmpty)
  }

  /// Asked-for usage goes to stdout and exits 0, so `e05 help | less`
  /// works; the same text on the error paths above goes to stderr.
  @Test("help prints usage on stdout and exits 0")
  func helpExitsZero() async throws {
    for argument in ["help", "--help", "-h"] {
      let run = try await runCLI([argument], socketPath: nil)
      #expect(run.status == 0)
      #expect(run.stdout.contains("Usage: e05"))
      // Which stream it came out of, not whether the child was silent:
      // a loader warning on stderr is not this test's business.
      #expect(!run.stderr.contains("Usage: e05"))
    }
  }
}

// MARK: - Socket discovery

/// With no `E05_SOCKET`, the CLI walks up from its own executable to the
/// enclosing `.app` and reads `CFBundleIdentifier`, which is how the copy
/// inside e05[DEV].app talks to the dev host while the release copy talks
/// to the release one. Getting it wrong routes a pane into the other
/// build, and nothing about the failure says why.
@Suite("e05 CLI socket discovery")
@MainActor
struct CLISocketDiscoveryTests {
  /// A bundle id no real build uses, so a case that reached a live host
  /// by mistake would fail rather than drive the developer's own app.
  static let identifier = "com.kawarimidoll.e05.cli-test"

  /// Stages the CLI where it actually ships — `<app>/Contents/MacOS`.
  /// `directory` is the caller's, so a throw partway through still
  /// leaves the caller's teardown holding everything written so far.
  private func stageBundle(in directory: URL) throws -> URL {
    let macOS = directory.appendingPathComponent("Fake.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let executable = macOS.appendingPathComponent("e05")
    try FileManager.default.copyItem(at: cliURL, to: executable)
    let plist = ["CFBundleIdentifier": Self.identifier]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: directory.appendingPathComponent("Fake.app/Contents/Info.plist"))
    return executable
  }

  /// No host is started: the transport error names the path it derived,
  /// which is the only place that decision is observable.
  ///
  /// The expectation is built from `E05Paths` rather than spelled out,
  /// because the CLI does not depend on E05Lib and carries its own copy
  /// of the socket name — `main.swift` says as much and asks for the two
  /// to be kept in sync. A literal here would agree with the CLI's
  /// literal forever; going through the library makes the case fail when
  /// they part.
  @Test("the socket path comes from the hosting bundle's identifier")
  func derivesSocketFromBundle() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let executable = try stageBundle(in: dir)
    let expected = E05Paths(
      env: [:],
      bundleIdentifier: Self.identifier,
      home: FileManager.default.homeDirectoryForCurrentUser
    ).dataFile(E05Filenames.controlSocket).path

    let run = try await runCLI(
      ["action", "focus_right"], socketPath: nil, executable: executable)
    #expect(run.status == 3)
    #expect(run.stderr.contains(expected))
  }

  /// The env override is what every case above relies on, and what a
  /// developer uses to aim the CLI at a second build — it has to beat
  /// the bundle it is sitting in, not merely fill in for a missing one.
  @Test("E05_SOCKET overrides the bundle it is sitting in")
  func environmentBeatsBundle() async throws {
    let dir = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let executable = try stageBundle(in: dir)

    try await withHost { host, socket in
      let run = try await runCLI(
        ["action", "focus_right"], socketPath: socket, executable: executable)
      #expect(run.status == 0)
      #expect(described(host.requests.first) == "action focus_right")
    }
  }
}
