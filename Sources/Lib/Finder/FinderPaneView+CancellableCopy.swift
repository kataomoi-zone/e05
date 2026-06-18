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

/// Thread-safe byte tally for a copy batch's determinate progress bar. The
/// off-main `copyfile` callback streams the in-flight plan's bytes into
/// `currentPlanBytes`; the batch loop credits each finished plan's
/// pre-tallied size into `completedPlansBytes`; the main-actor progress
/// panel reads `fraction` / `byteSummary` on a timer. `totalBytes` stays
/// nil until the size pre-walk finishes, which keeps the bar indeterminate
/// during the "preparing" phase (Finder shows the same before a copy).
public final class FinderCopyProgress: Sendable {
  private struct State {
    var totalBytes: Int64?
    var completedPlansBytes: Int64 = 0
    var currentPlanBytes: Int64 = 0
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  func setTotalBytes(_ total: Int64) { state.withLock { $0.totalBytes = total } }
  func setCurrentPlanBytes(_ bytes: Int64) {
    state.withLock { $0.currentPlanBytes = bytes }
  }
  /// Credit a finished plan's full pre-tallied size and clear the in-flight
  /// counter, so a clone (which streams no callback bytes) still advances
  /// the bar and the running total never drifts from the walked size.
  func completePlan(bytes: Int64) {
    state.withLock {
      $0.completedPlansBytes += bytes
      $0.currentPlanBytes = 0
    }
  }
  /// Drop a failed plan's streamed bytes without crediting them.
  func discardCurrentPlan() { state.withLock { $0.currentPlanBytes = 0 } }

  /// 0...1 completion, or nil while the total is still being tallied
  /// (→ indeterminate bar).
  var fraction: Double? {
    state.withLock { s in
      guard let total = s.totalBytes, total > 0 else { return nil }
      let copied = s.completedPlansBytes + s.currentPlanBytes
      return min(1.0, max(0.0, Double(copied) / Double(total)))
    }
  }
  /// Copied / total bytes for a "1.2 GB of 15 GB" label, or nil until the
  /// total is known.
  var byteSummary: (copied: Int64, total: Int64)? {
    state.withLock { s in
      guard let total = s.totalBytes else { return nil }
      return (min(s.completedPlansBytes + s.currentPlanBytes, total), total)
    }
  }
}

/// Per-copy context handed to `copyfile`'s status callback through its
/// opaque pointer: the cancellation flag, a slot for the real errno
/// captured at the error stage before `COPYFILE_QUIT` overwrites it, the
/// optional progress tally, and the running on-disk size of files already
/// finished within this (possibly recursive) copy — credited per file so
/// the bar tracks a clone, which streams no per-byte `COPYFILE_COPY_DATA`.
private final class CopyfileContext {
  let token: CopyCancellationToken
  let progress: FinderCopyProgress?
  var errorCode: Int32 = 0
  var creditedBytes: Int64 = 0
  init(token: CopyCancellationToken, progress: FinderCopyProgress?) {
    self.token = token
    self.progress = progress
  }
}

/// Logical size (`st_size`) of the file at C path `path`, read with `lstat`
/// so it can be called from inside the @convention(c) copyfile callback.
/// Matches the logical sizes `totalSize` tallies as the progress denominator
/// — and what Finder shows in its Size column. The on-disk allocated size
/// (`st_blocks` × 512) can be far smaller for an APFS-cloned bundle like
/// Xcode.app, where many files share blocks, so it's the wrong metric here.
private func fileLogicalSize(_ path: UnsafePointer<CChar>) -> Int64 {
  var info = stat()
  guard lstat(path, &info) == 0 else { return 0 }
  return Int64(info.st_size)
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
  /// half-written file is left behind. `progress`, when supplied, receives
  /// the in-flight byte count for a determinate progress bar.
  nonisolated static func cancellableCopy(
    from source: URL, to target: URL, token: CopyCancellationToken,
    progress: FinderCopyProgress? = nil
  ) -> CopyOutcome {
    let state = copyfile_state_alloc()
    defer { copyfile_state_free(state) }

    // A @convention(c) callback can't capture Swift state, so the context
    // travels through copyfile's status pointer. Abort as soon as the flag
    // is set, and on an error stage — continuing past a data-copy error
    // makes copyfile retry the same write, which never terminates on a
    // persistent failure such as a full destination (stash the real errno
    // first, since COPYFILE_QUIT then sets it to ECANCELED). For the
    // progress bar, stream the in-flight file's bytes on each data tick and
    // credit each finished file's logical size — a same-volume clone copies
    // no data bytes, so per-file credit is the only signal that moves it.
    let context = CopyfileContext(token: token, progress: progress)
    let callback: copyfile_callback_t = { what, stage, copyState, _, dst, ctx in
      guard let ctx else { return COPYFILE_CONTINUE }
      let context = Unmanaged<CopyfileContext>.fromOpaque(ctx)
        .takeUnretainedValue()
      if context.token.isCancelled { return COPYFILE_QUIT }
      if stage == COPYFILE_ERR {
        context.errorCode = errno
        return COPYFILE_QUIT
      }
      guard let progress = context.progress else { return COPYFILE_CONTINUE }
      if what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS {
        // A large file copied byte-by-byte: add this file's bytes so far to
        // the running credit for an intra-file-smooth bar.
        var copied: off_t = 0
        copyfile_state_get(copyState, UInt32(COPYFILE_STATE_COPIED), &copied)
        progress.setCurrentPlanBytes(context.creditedBytes + Int64(copied))
      } else if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
        // A file in the tree finished. A clone copies no data bytes, so
        // COPYFILE_COPY_DATA never fires for it — crediting the file's
        // logical size here is what advances the bar for a same-volume APFS
        // duplicate, where the byte counter alone would sit at 0. This
        // per-file credit isn't hard-link-deduped like the `totalSize`
        // denominator, so a hard-link-heavy bundle can push the numerator
        // past the total — `fraction` clamps at 100% and `completePlan`
        // snaps it exactly on the plan's completion.
        if let dst {
          context.creditedBytes += fileLogicalSize(dst)
        }
        progress.setCurrentPlanBytes(context.creditedBytes)
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

  /// Total size of `url` the way Finder's Size column reports it (matching
  /// `du -A`): the sum of apparent (logical `st_size`) byte sizes, counting
  /// each hard-linked inode once and not following symlinks. Used off-main
  /// as the package Size cell and the copy progress bar's denominator.
  ///
  /// Both naive metrics are wrong, in opposite directions. A plain
  /// `fileSize` sum over-counts: it re-counts hard-linked inodes and
  /// follows symlinks to re-count their targets — Xcode.app does enough of
  /// both to read ~5% high (12.48 GB vs Finder's 11.89). On-disk allocated
  /// size under-counts: an APFS clone shares blocks, so Xcode.app allocates
  /// only ~5 GB. Best-effort: unreadable entries contribute 0.
  nonisolated static func totalSize(of url: URL) -> Int64 {
    struct FileID: Hashable {
      let device: dev_t
      let inode: ino_t
    }
    var seen = Set<FileID>()
    var total: Int64 = 0

    func tally(_ path: String) {
      var info = stat()
      guard lstat(path, &info) == 0 else { return }
      // A hard-linked inode recurs under several paths; count it once.
      guard seen.insert(FileID(device: info.st_dev, inode: info.st_ino)).inserted
      else { return }
      total += Int64(info.st_size)
    }

    tally(url.path(percentEncoded: false))
    let isDirectory =
      (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    guard isDirectory else { return total }

    if let enumerator = FileManager().enumerator(
      at: url, includingPropertiesForKeys: nil, options: [])
    {
      for case let child as URL in enumerator {
        tally(child.path(percentEncoded: false))
      }
    }
    return total
  }
}
