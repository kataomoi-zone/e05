import Foundation
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "DirectoryMonitor")

/// Watches a single directory for contents changes via a kqueue-backed
/// `DispatchSource`. The handler fires on main when the directory's
/// inode reports `.write` (add/remove/move of child), `.rename` (the
/// directory itself was renamed), or `.delete`.
///
/// One monitor tracks one directory at a time; calling `start(at:)`
/// again swaps the watched path. `stop()` is idempotent and is called
/// automatically on deinit so leaking a monitor doesn't leak a file
/// descriptor.
@MainActor
public final class DirectoryMonitor {
  public var onChange: (() -> Void)?

  private var source: DispatchSourceFileSystemObject?
  private var fileDescriptor: CInt = -1

  public init() {}

  public func start(at url: URL) {
    stop()

    let path = url.path(percentEncoded: false)
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
      logger.warning("Failed to open \(path, privacy: .public) for monitoring (errno \(errno))")
      return
    }

    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .rename, .delete],
      queue: .main
    )
    src.setEventHandler { [weak self] in
      self?.onChange?()
    }
    src.setCancelHandler { [fd] in
      close(fd)
    }
    src.resume()

    self.fileDescriptor = fd
    self.source = src
  }

  public func stop() {
    source?.cancel()
    source = nil
    fileDescriptor = -1
  }

  deinit {
    source?.cancel()
  }
}
