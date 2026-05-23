import Foundation
import WebKit
import os

private let logger = Logger(subsystem: LogSubsystem.app, category: "NativeMessaging")

/// Layout of a Chrome / Firefox / Edge native messaging host manifest.
/// Each browser drops a JSON file under
/// `~/Library/Application Support/<vendor>/NativeMessagingHosts/<host name>.json`
/// describing the binary that should be launched when an extension calls
/// `chrome.runtime.connectNative(<host name>)`. The two list shapes
/// (`allowed_origins` for Chromium, `allowed_extensions` for Firefox)
/// gate which extensions are authorised to talk to the host.
struct NativeMessagingManifest: Decodable {
  let name: String
  let path: String
  let type: String
  let description: String?
  let allowedOrigins: [String]?
  let allowedExtensions: [String]?

  enum CodingKeys: String, CodingKey {
    case name, path, type, description
    case allowedOrigins = "allowed_origins"
    case allowedExtensions = "allowed_extensions"
  }
}

/// Resolves native messaging host manifests for a given host name.
/// Walks the per-user manifest roots that Chrome / Firefox / Edge / Brave
/// share by convention; the first matching `stdio` manifest wins, with
/// per-user paths taking precedence over system-wide ones because that
/// matches the lookup order browsers themselves use.
enum NativeMessagingHostRegistry {
  /// Manifest search roots ordered per-user first, then system-wide.
  /// Bitwarden Desktop installs into the per-user paths only; the
  /// system-wide entries cover enterprise / managed deployments that
  /// drop manifests under `/Library`.
  private static let searchRoots: [String] = [
    "~/Library/Application Support/Google/Chrome/NativeMessagingHosts",
    "~/Library/Application Support/Mozilla/NativeMessagingHosts",
    "~/Library/Application Support/Microsoft Edge/NativeMessagingHosts",
    "~/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
    "/Library/Application Support/Google/Chrome/NativeMessagingHosts",
    "/Library/Application Support/Mozilla/NativeMessagingHosts",
    "/Library/Application Support/Microsoft Edge/NativeMessagingHosts",
  ]

  static func manifest(forHost name: String) -> NativeMessagingManifest? {
    let fm = FileManager.default
    let filename = "\(name).json"
    for root in searchRoots {
      let expanded = (root as NSString).expandingTildeInPath
      let url = URL(fileURLWithPath: expanded).appendingPathComponent(filename)
      guard fm.fileExists(atPath: url.path),
        let data = try? Data(contentsOf: url),
        let manifest = try? JSONDecoder().decode(NativeMessagingManifest.self, from: data)
      else { continue }
      guard manifest.type == "stdio" else {
        logger.error(
          "Native host '\(name, privacy: .public)' has unsupported type='\(manifest.type, privacy: .public)'"
        )
        continue
      }
      logger.info(
        "Resolved native host '\(name, privacy: .public)' → \(manifest.path, privacy: .public)"
      )
      return manifest
    }
    return nil
  }
}

/// Bridges a `WKWebExtension.MessagePort` to a Chrome-style native messaging
/// host subprocess. The host is launched with the calling extension's origin
/// as `argv[1]` (Chrome convention — Bitwarden Desktop routes encryption
/// channels by this identifier) and exchanges length-prefixed JSON frames
/// over stdin / stdout per the Native Messaging spec.
///
/// Retain a reference for as long as the connection should stay alive:
/// releasing the port on the WebKit side disconnects it (Apple SDK
/// contract for
/// `WKWebExtensionControllerDelegate.webExtensionController(_:connectUsing:for:completionHandler:)`),
/// and dropping this object terminates the subprocess via
/// `shutdown(reason:)`.
@MainActor
final class NativeMessagingPort {
  private let port: WKWebExtension.MessagePort
  private let process: Process
  /// Retain the Pipe objects explicitly. Process holds them via its
  /// standardInput / standardOutput properties, so this is belt-and-
  /// suspenders, but during early-stage bringup it removes one
  /// possible class of "fd closed prematurely" failures.
  private let stdinPipe: Pipe
  private let stdoutPipe: Pipe
  private let stderrPipe: Pipe
  private let stdin: FileHandle
  private let stdout: FileHandle
  private let stderr: FileHandle
  private var readTask: Task<Void, Never>?
  private var stderrTask: Task<Void, Never>?
  /// Invoked when the host process or read loop terminates so the
  /// owning controller can drop its retain on this port.
  var onClosed: (@MainActor () -> Void)?
  private(set) var isClosed = false
  let manifestPath: String
  /// The `WKWebExtensionContext` that requested this port. Retained
  /// so the owning controller can pool ports by `(context, manifest)`
  /// — the extension's service worker reconnects across its
  /// suspend/resume cycle without WebKit firing `disconnectHandler`
  /// on the prior port, so duplicates must be collapsed at connect
  /// time.
  let context: WKWebExtensionContext

  init(
    port: WKWebExtension.MessagePort,
    manifest: NativeMessagingManifest,
    callerOrigin: String?,
    context: WKWebExtensionContext
  ) throws {
    self.port = port
    self.manifestPath = manifest.path
    self.context = context
    logger.info("Spawning host name=\(manifest.name, privacy: .public) path=\(manifest.path, privacy: .public) origin=\(callerOrigin ?? "(none)", privacy: .public)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: manifest.path)
    if let origin = callerOrigin {
      process.arguments = [origin]
    }
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    // Use a pipe (not inherited stderr) so the host's diagnostic
    // output is line-buffered into os.Logger with a clear `[stderr]`
    // tag. Inheriting standardError sent the bytes to e05's stderr
    // raw, which interleaved unpredictably with os.Logger output and
    // made it hard to correlate proxy crashes with the surrounding
    // bridge events.
    process.standardError = stderrPipe
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe
    self.stdin = stdinPipe.fileHandleForWriting
    self.stdout = stdoutPipe.fileHandleForReading
    self.stderr = stderrPipe.fileHandleForReading
    // Wire termination logging *before* spawning so Process can
    // never deliver the callback before our handler is set.
    process.terminationHandler = { proc in
      logger.info("host process terminated pid=\(proc.processIdentifier) status=\(proc.terminationStatus) reason=\(proc.terminationReason == .exit ? "exit" : "uncaughtSignal", privacy: .public)")
    }
    try process.run()
    logger.info(
      "Native host launched pid=\(process.processIdentifier) path=\(manifest.path, privacy: .public) origin=\(callerOrigin ?? "(none)", privacy: .public)"
    )
    configureBridges()
    startReadLoop()
    startStderrLoop()
    scheduleEarlyExitCheck()
  }

  /// Detect a host that exits within the first 500ms after spawn.
  /// Bitwarden's `desktop_proxy` does this when its IPC link to the
  /// Electron main process can't be established (Bitwarden Desktop
  /// not running, browser-integration toggle off, IPC socket
  /// missing), and the proxy's stderr alone doesn't make the failure
  /// obvious. Logging an explicit "exited within Nms" line gives the
  /// reader a single anchor to scan for.
  private func scheduleEarlyExitCheck() {
    let pid = process.processIdentifier
    let path = manifestPath
    Task.detached { [weak self] in
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard let self else { return }
      await MainActor.run {
        // Suppress the WARN when *we* tore the host down inside the
        // 500ms window (extension disable, popup close, app quit).
        // Without this guard a clean self-shutdown looks identical
        // to a launch crash and clutters the log with false leads.
        guard !self.isClosed else { return }
        if !self.process.isRunning {
          logger.error("WARN host exited within 500ms pid=\(pid) status=\(self.process.terminationStatus) path=\(path, privacy: .public)")
        } else {
          logger.debug("host still alive after 500ms pid=\(pid)")
        }
      }
    }
  }

  /// Drain the host's stderr line-by-line into os.Logger. Uses
  /// readabilityHandler so partial lines coming from a panicking host
  /// still flush before the process dies.
  private func startStderrLoop() {
    let handle = stderr
    stderrTask = Task.detached {
      while !Task.isCancelled {
        guard let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty else {
          return
        }
        let text = String(data: chunk, encoding: .utf8) ?? "(binary \(chunk.count) bytes)"
        for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
          logger.info("[stderr] \(String(line), privacy: .public)")
        }
      }
    }
  }

  private func configureBridges() {
    port.messageHandler = { [weak self] message, error in
      guard let self else { return }
      if let error {
        logger.error("messageHandler error: \(error.localizedDescription, privacy: .public)")
        return
      }
      let preview = NativeMessagingPort.previewDescription(of: message)
      logger.debug("ext→host message: \(preview, privacy: .public)")
      self.send(toHost: message)
    }
    port.disconnectHandler = { [weak self] error in
      let detail = error?.localizedDescription ?? "(no error)"
      logger.debug("port disconnectHandler fired: \(detail, privacy: .public)")
      self?.shutdown(reason: "extension disconnected")
    }
    logger.info("configureBridges done (handlers attached)")
  }

  /// Best-effort one-line summary of an `Any` payload for log output.
  /// Strings are truncated, dictionaries shrink to their key list, so a
  /// large encrypted handshake blob doesn't dump 64KB into the log.
  private static func previewDescription(of message: Any?) -> String {
    guard let message else { return "(nil)" }
    if let dict = message as? [String: Any] {
      let keys = dict.keys.sorted().joined(separator: ",")
      return "[dict keys=\(keys) count=\(dict.count)]"
    }
    if let arr = message as? [Any] {
      return "[array count=\(arr.count)]"
    }
    let s = String(describing: message)
    return s.count > 120 ? String(s.prefix(120)) + "…" : s
  }

  /// Encode a JSON-serialisable payload as `<4 byte little-endian length><utf-8 JSON>`
  /// and write it to the host's stdin. Returns silently on JSON errors so a
  /// single malformed message from the extension doesn't tear the port down;
  /// pipe errors do trigger shutdown because the host is no longer reachable.
  private func send(toHost message: Any?) {
    guard let message else {
      logger.error("send(toHost:) skipped (nil message)")
      return
    }
    // WebKit's MessagePort delivers JSON values; the extension can pass
    // primitives (`true`, `42`, `"hello"`) and JSONSerialization rejects
    // those at the top level (it requires array or object). Wrap such
    // payloads as `[primitive]` would be wrong for the host — instead
    // serialize via .fragmentsAllowed so the wire format matches what
    // Chrome / Firefox put on the pipe (JSON values, not just objects).
    let data: Data
    do {
      data = try JSONSerialization.data(
        withJSONObject: message, options: [.fragmentsAllowed]
      )
    } catch {
      logger.error("JSON encode failed for ext→host payload: \(error.localizedDescription, privacy: .public)")
      return
    }
    var length = UInt32(data.count).littleEndian
    var combined = Data(capacity: 4 + data.count)
    withUnsafeBytes(of: &length) { combined.append(contentsOf: $0) }
    combined.append(data)
    do {
      // Single syscall for header + body so a partial read on the host
      // side can never observe a length prefix without its payload.
      try stdin.write(contentsOf: combined)
      let body = String(data: data, encoding: .utf8) ?? "(binary)"
      let preview = body.count > 200 ? String(body.prefix(200)) + "…" : body
      logger.debug("wrote \(data.count) bytes to host stdin: \(preview, privacy: .public)")
    } catch {
      logger.error("stdin write failed (\(data.count) bytes): \(error.localizedDescription, privacy: .public)")
      shutdown(reason: "stdin write failed")
    }
  }

  /// Continuous reader for the host's stdout. Each frame is a 4-byte
  /// little-endian length prefix followed by JSON bytes that we forward
  /// to the extension via `port.sendMessage`. Runs detached so the read
  /// blocks don't pin the main actor; payload delivery hops back via
  /// `MainActor.run` because both `WKWebExtension.MessagePort` and our
  /// teardown logic are main-actor isolated.
  private func startReadLoop() {
    let handle = stdout
    logger.debug("startReadLoop entering detached task")
    readTask = Task.detached { [weak self] in
      while !Task.isCancelled {
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else {
          logger.error("read loop hit EOF on header read")
          await MainActor.run { [weak self] in
            self?.shutdown(reason: "stdout EOF")
          }
          return
        }
        let length = header.withUnsafeBytes { ptr in
          UInt32(littleEndian: ptr.load(as: UInt32.self))
        }
        guard length > 0, length < 64 * 1024 * 1024 else {
          // Defensive cap: native messaging spec advises 64MB max per
          // frame. A larger value almost always means we lost framing.
          await MainActor.run { [weak self] in
            self?.shutdown(reason: "stdout invalid frame length \(length)")
          }
          return
        }
        let count = Int(length)
        guard let body = try? handle.read(upToCount: count), body.count == count else {
          logger.error("read loop got truncated body (wanted \(count))")
          await MainActor.run { [weak self] in
            self?.shutdown(reason: "stdout truncated payload")
          }
          return
        }
        logger.debug("host→ext frame \(count) bytes")
        await MainActor.run { [weak self] in
          self?.deliverFromHost(body)
        }
      }
    }
  }

  private func deliverFromHost(_ frame: Data) {
    guard !port.isDisconnected else {
      logger.error("deliverFromHost skipped: port already disconnected")
      return
    }
    let payload: Any
    do {
      payload = try JSONSerialization.jsonObject(
        with: frame, options: [.fragmentsAllowed]
      )
    } catch {
      // Skip malformed frames rather than tearing down the channel —
      // the host may emit diagnostic noise the extension can ignore.
      logger.error("host emitted non-JSON payload (\(frame.count) bytes): \(error.localizedDescription, privacy: .public)")
      return
    }
    let body = String(data: frame, encoding: .utf8) ?? "(binary)"
    let bodyPreview = body.count > 200 ? String(body.prefix(200)) + "…" : body
    logger.debug("forwarding to ext (\(frame.count) bytes): \(bodyPreview, privacy: .public)")
    port.sendMessage(payload) { error in
      if let error {
        logger.error("sendMessage to ext failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func shutdown(reason: String) {
    guard !isClosed else { return }
    isClosed = true
    logger.info("shutdown reason=\(reason, privacy: .public)")
    readTask?.cancel()
    readTask = nil
    stderrTask?.cancel()
    stderrTask = nil
    try? stdin.close()
    try? stdout.close()
    try? stderr.close()
    if process.isRunning {
      process.terminate()
      // Most well-behaved hosts (Bitwarden's desktop_proxy included)
      // exit on SIGTERM within milliseconds, but a host that ignores
      // the signal (or one stuck inside an uninterruptible syscall)
      // would otherwise stay around as a zombie until the user logs
      // out. Schedule a SIGKILL fallback so teardown is bounded.
      let pidToKill = process.processIdentifier
      let proc = process
      Task.detached {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if proc.isRunning {
          logger.error("host did not exit on SIGTERM, sending SIGKILL pid=\(pidToKill)")
          kill(pidToKill, SIGKILL)
        }
      }
    }
    if !port.isDisconnected {
      port.disconnect()
    }
    onClosed?()
    onClosed = nil
  }
}
