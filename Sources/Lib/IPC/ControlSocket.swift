import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "ControlSocket")

/// Single-line JSON request/response over an `AF_UNIX` socket. Each
/// accepted connection serves one request and closes; the listener
/// is op-agnostic and forwards every parsed `Request` to the
/// host-supplied handler closure for dispatch.
public final class ControlSocket: @unchecked Sendable {
  public struct Request: Decodable {
    public let op: String
    public let url: String?
  }

  public struct Response: Encodable, Sendable {
    public let ok: Bool
    public let error: String?
    public init(ok: Bool, error: String? = nil) {
      self.ok = ok
      self.error = error
    }
  }

  /// Invoked once per request, hopped onto the main actor by the
  /// listener so handlers can touch `paneContainer` / model state
  /// directly. Long-running work should `Task { ... }` off the actor.
  public typealias Handler = @MainActor (Request) -> Response

  private let socketPath: String
  private let handler: Handler
  private let queue = DispatchQueue(label: "com.kawarimidoll.e05.ipc")
  private var listenFd: Int32 = -1
  private var acceptSource: (any DispatchSourceRead)?

  public init(socketPath: String, handler: @escaping Handler) {
    self.socketPath = socketPath
    self.handler = handler
  }

  /// Bind, listen, and start accepting. Throws on socket / bind /
  /// listen failure; the caller decides whether the host should still
  /// boot without IPC. Throws `POSIXError(.EADDRINUSE)` specifically
  /// when another live process is already listening on the same path
  /// — the caller should treat that as a duplicate-instance signal
  /// and abort rather than continuing.
  public func start() throws {
    // Probe before unlinking: an `unlink + bind` combination would
    // succeed even when a sibling process is mid-`accept` on the old
    // socket, silently routing every new client to this instance and
    // leaving the original one with a leaked listener. A successful
    // probe connect proves that sibling is still alive and responsive.
    if probeExistingListener() {
      throw POSIXError(.EADDRINUSE)
    }
    // Drop a stale socket file from a prior crash; bind() rejects
    // an existing path even when no process is listening.
    unlink(socketPath)

    let dir = (socketPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw posixError() }
    // Children spawned by ghostty (or anything else) must not inherit
    // the listener — otherwise they keep the socket alive past
    // applicationWillTerminate's unlink.
    if fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 {
      logger.error("[ipc] FD_CLOEXEC failed errno=\(errno)")
    }
    // Non-blocking listen FD so the accept loop can drain the backlog
    // (multiple short-lived `e05` invocations land within one
    // `DispatchSource` fire) and break on `EAGAIN` without stalling.
    let flags = fcntl(fd, F_GETFL, 0)
    if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
      logger.error("[ipc] O_NONBLOCK setup failed errno=\(errno)")
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= maxPath else {
      close(fd)
      throw POSIXError(.ENAMETOOLONG)
    }
    _ = socketPath.withCString { src in
      withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPath) {
          strlcpy($0, src, maxPath)
        }
      }
    }

    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      let err = errno
      close(fd)
      throw posixError(err)
    }

    // Restrict the socket to the owning user — single-user Mac is the
    // current threat model, but the file mode protects against a
    // future second-user account on the same machine.
    chmod(socketPath, 0o600)

    guard listen(fd, 32) == 0 else {
      let err = errno
      close(fd)
      unlink(socketPath)
      throw posixError(err)
    }

    listenFd = fd
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in
      self?.acceptOnce()
    }
    // FD close + path unlink happen in the cancel handler so `stop()`
    // can post the cancel and return without racing the accept queue
    // against a freshly-closed FD.
    let listenFdCopy = fd
    let pathCopy = socketPath
    source.setCancelHandler {
      close(listenFdCopy)
      unlink(pathCopy)
    }
    source.resume()
    acceptSource = source

    logger.info("[ipc] listening at \(self.socketPath, privacy: .public)")
  }

  /// Try to connect to `socketPath` to detect a live sibling
  /// listener. Returns `true` only when `connect(2)` succeeds; missing
  /// path / `ECONNREFUSED` (= stale file, no one accepting) returns
  /// `false` so the regular bind path can claim ownership.
  private func probeExistingListener() -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
    guard socketPath.utf8CString.count <= maxPath else { return false }
    _ = socketPath.withCString { src in
      withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
        tuplePtr.withMemoryRebound(to: CChar.self, capacity: maxPath) {
          strlcpy($0, src, maxPath)
        }
      }
    }
    let result = withUnsafePointer(to: &addr) { addrPtr in
      addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return result == 0
  }

  public func stop() {
    acceptSource?.cancel()
    acceptSource = nil
    listenFd = -1
  }

  // MARK: - Accept / per-connection handling

  /// Drain every pending connection on each `DispatchSource` fire. The
  /// listen FD is `O_NONBLOCK`, so the loop terminates on
  /// `EAGAIN` once the backlog is empty.
  private func acceptOnce() {
    while true {
      guard listenFd >= 0 else { return }
      let clientFd = accept(listenFd, nil, nil)
      if clientFd < 0 {
        let err = errno
        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR { return }
        if err == EBADF || err == EINVAL {
          logger.error("[ipc] accept fatal errno=\(err), cancelling source")
          acceptSource?.cancel()
          return
        }
        logger.error("[ipc] accept failed errno=\(err)")
        return
      }
      // Accepted sockets on Darwin inherit `O_NONBLOCK` from the
      // listen FD, which would short-circuit every blocking
      // `read()` with `EAGAIN` long before the client finishes
      // writing. Clear the flag so `SO_RCVTIMEO` / `SO_SNDTIMEO`
      // below can actually bound the call.
      let clientFlags = fcntl(clientFd, F_GETFL, 0)
      if clientFlags < 0
        || fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK) < 0
      {
        logger.error("[ipc] clear O_NONBLOCK on client failed errno=\(errno)")
      }
      // Per-client send/receive timeout so a stalled client cannot
      // park the ipc queue indefinitely (the queue is single-threaded
      // and serialises every accept).
      var tv = timeval(tv_sec: 5, tv_usec: 0)
      let tvLen = socklen_t(MemoryLayout<timeval>.size)
      _ = setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
      _ = setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)
      handleClient(fd: clientFd)
    }
  }

  /// Synchronous, single-request-per-connection: read until newline,
  /// dispatch, write reply, close. Sufficient for the MVP request set
  /// (each shell invocation makes one round trip and exits).
  private func handleClient(fd: Int32) {
    defer { close(fd) }

    var collected = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let lineLimit = 1 << 20  // 1 MiB safety cap; protocol is single-line JSON

    outer: while true {
      let n = buffer.withUnsafeMutableBufferPointer { ptr in
        Darwin.read(fd, ptr.baseAddress, ptr.count)
      }
      if n < 0 {
        let err = errno
        if err == EINTR { continue }
        logger.error("[ipc] read failed errno=\(err)")
        writeResponse(fd: fd, response: Response(ok: false, error: "read failed"))
        return
      }
      if n == 0 { break }
      for i in 0..<n {
        if buffer[i] == UInt8(ascii: "\n") {
          collected.append(buffer, count: i)
          break outer
        }
      }
      collected.append(buffer, count: n)
      if collected.count > lineLimit {
        logger.error("[ipc] request exceeded \(lineLimit) bytes, closing")
        writeResponse(fd: fd, response: Response(ok: false, error: "request too large"))
        return
      }
    }

    let request: Request
    do {
      request = try JSONDecoder().decode(Request.self, from: collected)
    } catch {
      logger.error("[ipc] decode failed: \(error.localizedDescription, privacy: .public)")
      writeResponse(fd: fd, response: Response(ok: false, error: "invalid json"))
      return
    }

    // `async` + semaphore (instead of `main.sync`) so a future
    // main-thread caller of any ControlSocket method does not risk a
    // queue-pinning deadlock with the ipc queue's pending hop.
    let handler = self.handler
    let box = ResponseBox()
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        box.value = handler(request)
      }
      sem.signal()
    }
    sem.wait()
    writeResponse(fd: fd, response: box.value)
  }

  /// Reference holder so the ipc queue can read what the main-actor
  /// hop produced without violating Swift 6 concurrency-checked
  /// captures.
  private final class ResponseBox: @unchecked Sendable {
    var value = Response(ok: false, error: "main hop did not run")
  }

  private func writeResponse(fd: Int32, response: Response) {
    guard var data = try? JSONEncoder().encode(response) else {
      logger.error("[ipc] failed to encode response")
      return
    }
    data.append(UInt8(ascii: "\n"))
    let written = data.withUnsafeBytes { ptr in
      Darwin.write(fd, ptr.baseAddress, ptr.count)
    }
    if written < 0 {
      logger.error("[ipc] write failed errno=\(errno)")
    }
  }

  private func posixError(_ err: Int32 = errno) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
  }
}
