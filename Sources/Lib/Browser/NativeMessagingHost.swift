import Foundation
import WebKit
import os

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "NativeMessaging")

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
/// releasing the port on the WebKit side disconnects it (Apple SDK contract,
/// `WKWebExtensionControllerDelegate.h:198-199`), and dropping this object
/// terminates the subprocess via `shutdown(reason:)`.
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
  private let stdin: FileHandle
  private let stdout: FileHandle
  private var readTask: Task<Void, Never>?
  /// Invoked when the host process or read loop terminates so the
  /// owning controller can drop its retain on this port.
  var onClosed: (@MainActor () -> Void)?
  private(set) var isClosed = false

  init(
    port: WKWebExtension.MessagePort,
    manifest: NativeMessagingManifest,
    callerOrigin: String?
  ) throws {
    self.port = port
    let process = Process()
    process.executableURL = URL(fileURLWithPath: manifest.path)
    if let origin = callerOrigin {
      process.arguments = [origin]
    }
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    // Inherit stderr so the host's diagnostic output flows into the
    // same console stream as the rest of the app — useful when a host
    // crashes during the encryption handshake.
    process.standardError = FileHandle.standardError
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stdin = stdinPipe.fileHandleForWriting
    self.stdout = stdoutPipe.fileHandleForReading
    try process.run()
    NSLog(
      "[e05/nm] Launched host pid=%d path=%@ origin=%@",
      process.processIdentifier, manifest.path, callerOrigin ?? "(none)"
    )
    logger.info(
      "Native host launched pid=\(process.processIdentifier) path=\(manifest.path, privacy: .public) origin=\(callerOrigin ?? "(none)", privacy: .public)"
    )
    configureBridges()
    startReadLoop()
  }

  private func configureBridges() {
    port.messageHandler = { [weak self] message, error in
      guard let self else { return }
      if let error {
        NSLog("[e05/nm] messageHandler error: %@", error.localizedDescription)
        return
      }
      let preview = NativeMessagingPort.previewDescription(of: message)
      NSLog("[e05/nm] ext→host message: %@", preview)
      self.send(toHost: message)
    }
    port.disconnectHandler = { [weak self] error in
      let detail = error?.localizedDescription ?? "(no error)"
      NSLog("[e05/nm] port disconnectHandler fired: %@", detail)
      self?.shutdown(reason: "extension disconnected")
    }
    NSLog("[e05/nm] configureBridges done (handlers attached)")
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
      NSLog("[e05/nm] send(toHost:) skipped (nil message)")
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
      NSLog(
        "[e05/nm] JSON encode failed for ext→host payload: %@",
        error.localizedDescription
      )
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
      NSLog("[e05/nm] wrote %d bytes to host stdin: %@", data.count, preview)
    } catch {
      NSLog(
        "[e05/nm] stdin write failed (%d bytes): %@",
        data.count, error.localizedDescription
      )
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
    NSLog("[e05/nm] startReadLoop entering detached task")
    readTask = Task.detached { [weak self] in
      while !Task.isCancelled {
        guard let header = try? handle.read(upToCount: 4), header.count == 4 else {
          NSLog("[e05/nm] read loop hit EOF on header read")
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
          NSLog("[e05/nm] read loop got truncated body (wanted %d)", count)
          await MainActor.run { [weak self] in
            self?.shutdown(reason: "stdout truncated payload")
          }
          return
        }
        NSLog("[e05/nm] host→ext frame %d bytes", count)
        await MainActor.run { [weak self] in
          self?.deliverFromHost(body)
        }
      }
    }
  }

  private func deliverFromHost(_ frame: Data) {
    guard !port.isDisconnected else {
      NSLog("[e05/nm] deliverFromHost skipped: port already disconnected")
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
      NSLog(
        "[e05/nm] host emitted non-JSON payload (%d bytes): %@",
        frame.count, error.localizedDescription
      )
      return
    }
    let body = String(data: frame, encoding: .utf8) ?? "(binary)"
    let bodyPreview = body.count > 200 ? String(body.prefix(200)) + "…" : body
    NSLog("[e05/nm] forwarding to ext (%d bytes): %@", frame.count, bodyPreview)
    port.sendMessage(payload) { error in
      if let error {
        NSLog(
          "[e05/nm] sendMessage to ext failed: %@",
          error.localizedDescription
        )
      }
    }
  }

  func shutdown(reason: String) {
    guard !isClosed else { return }
    isClosed = true
    NSLog("[e05/nm] shutdown reason=%@", reason)
    readTask?.cancel()
    readTask = nil
    try? stdin.close()
    try? stdout.close()
    if process.isRunning {
      process.terminate()
    }
    if !port.isDisconnected {
      port.disconnect()
    }
    onClosed?()
    onClosed = nil
  }
}
