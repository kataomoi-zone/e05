import Darwin
import Foundation
import os

private let logger = Logger(subsystem: LogSubsystem.app, category: "FinderPane")

/// Result of a `cancellableCopy`: the bytes fully landed, the user
/// cancelled mid-copy (the partial target has already been removed), or
/// the copy failed outright.
enum CopyOutcome {
  case completed
  case cancelled
  case failed(Error)
}

/// Thread-safe cancellation flag shared between a batch's detached copy
/// loop and the progress panel's ✕ button. The button (main actor) flips
/// it; the off-main `copyfile` status callback reads it on every progress
/// tick to decide whether to abort. A lock-guarded `Bool` is plenty — the
/// flag only ever moves false → true.
final class CopyCancellationToken: Sendable {
  private let cancelled = OSAllocatedUnfairLock(initialState: false)
  func cancel() { cancelled.withLock { $0 = true } }
  var isCancelled: Bool { cancelled.withLock { $0 } }
}

/// Per-copy context handed to `copyfile`'s status callback through its
/// opaque pointer: the cancellation flag plus a slot for the real errno,
/// captured at the error stage before `COPYFILE_QUIT` overwrites it.
private final class CopyfileContext {
  let token: CopyCancellationToken
  var errorCode: Int32 = 0
  init(token: CopyCancellationToken) { self.token = token }
}

extension FinderPaneView {
  /// Copy `source` → `target` interruptibly via `copyfile(3)`, the same
  /// system primitive Finder's copy uses, configured with a status callback
  /// that returns `COPYFILE_QUIT` the moment `token` is cancelled. Unlike
  /// `FileManager.copyItem` — atomic, with no per-file cancel hook — this
  /// aborts partway through a single large file, so the progress panel's ✕
  /// can stop a multi-GB copy instead of waiting for it to finish.
  /// `COPYFILE_CLONE` clones the source on a filesystem that supports it
  /// (APFS, same volume), finishing instantly with nothing to cancel, and
  /// otherwise falls back to a real recursive data copy the callback can
  /// interrupt — so every copy routes here, not just cross-volume ones.
  /// `FileManager.copyItem` does *not* clone, so a same-volume copy of a
  /// large bundle is a slow, uninterruptible byte copy; that's the case
  /// this replaces. `COPYFILE_CLONE` implies `COPYFILE_EXCL`, so callers
  /// must ensure `target` does not already exist — every drop / paste /
  /// duplicate path resolves a free slot, and Replace trashes the existing
  /// item first. On cancel or failure the partial target is removed so no
  /// half-written file is left behind.
  nonisolated static func cancellableCopy(
    from source: URL, to target: URL, token: CopyCancellationToken
  ) -> CopyOutcome {
    let state = copyfile_state_alloc()
    defer { copyfile_state_free(state) }

    // A @convention(c) callback can't capture Swift state, so the context
    // travels through copyfile's status pointer. The callback fires per
    // file and periodically during a file's data copy: abort as soon as
    // the flag is set, and also abort on an error stage — continuing past
    // a data-copy error makes copyfile retry the same write, which never
    // terminates on a persistent failure such as a full destination. Stash
    // the real errno first, since COPYFILE_QUIT then sets it to ECANCELED.
    let context = CopyfileContext(token: token)
    let callback: copyfile_callback_t = { _, stage, _, _, _, ctx in
      guard let ctx else { return COPYFILE_CONTINUE }
      let context = Unmanaged<CopyfileContext>.fromOpaque(ctx)
        .takeUnretainedValue()
      if context.token.isCancelled { return COPYFILE_QUIT }
      if stage == COPYFILE_ERR {
        context.errorCode = errno
        return COPYFILE_QUIT
      }
      return COPYFILE_CONTINUE
    }
    copyfile_state_set(
      state, UInt32(COPYFILE_STATE_STATUS_CB),
      unsafeBitCast(callback, to: UnsafeRawPointer.self))
    copyfile_state_set(
      state, UInt32(COPYFILE_STATE_STATUS_CTX),
      Unmanaged.passUnretained(context).toOpaque())

    let flags = copyfile_flags_t(COPYFILE_CLONE | COPYFILE_RECURSIVE)
    let result = copyfile(
      source.path(percentEncoded: false),
      target.path(percentEncoded: false),
      state, flags)
    if result == 0 { return .completed }

    // Resolve the failure code before any other call can clobber errno: the
    // callback stashed the real errno for an error abort, otherwise the
    // live errno still holds it. Then clear the partial target copyfile
    // leaves behind on abort.
    let code = context.errorCode != 0 ? context.errorCode : errno
    let fm = FileManager()
    if fm.fileExists(atPath: target.path(percentEncoded: false)) {
      do {
        try fm.removeItem(at: target)
      } catch {
        logger.error(
          "Cancellable copy: removing partial target \(target.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    // A cancel is identified by our own token, not errno: a COPYFILE_QUIT at
    // a non-progress stage can leave errno unmodified, and an error abort
    // sets it to ECANCELED, so neither errno value is a reliable signal.
    if token.isCancelled { return .cancelled }
    return .failed(NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
  }
}
