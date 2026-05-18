import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FinderPane")

/// Compress the selection into a ZIP archive next to the original
/// entries, mirroring Finder's right-click → Compress action. We
/// shell out to `/usr/bin/zip` because Foundation's
/// `NSFileCoordinator` / `FileManager` don't expose a built-in zip
/// writer; `zip(1)` is part of the macOS base install and produces
/// archives indistinguishable from Finder's own output (DEFLATE,
/// PKWARE format, no resource forks unless explicitly requested).
///
/// Naming follows Finder:
/// - Single entry → `<lastPathComponent>.zip`
///   (`foo.txt` → `foo.txt.zip`, `wallpapers/` → `wallpapers.zip`)
/// - Multiple entries → `Archive.zip`
/// - Collisions escalate to `<stem> 2.zip`, `<stem> 3.zip`, …
extension FinderPaneView {
  public func compressSelection() {
    let urls = selectedURLs
    guard !urls.isEmpty else { return }
    let archiveURL = compressTargetURL(for: urls)
    let cwd = currentURL
    // `zip -r` invoked with `currentDirectoryURL = cwd` and bare
    // last-component arguments stores entries by relative name,
    // so the resulting archive expands to the same directory
    // structure the user selected. Passing absolute URLs instead
    // would bake `/Users/<name>/…` segments into every entry.
    let relativeNames = urls.map { $0.lastPathComponent }
    let archiveName = archiveURL.lastPathComponent

    // Build the Process up front on MainActor so the cancel closure
    // and the detached task share the same instance: cancel calls
    // `terminate()` from MainActor, the task calls `run()` /
    // `waitUntilExit()` off-main. `Process` and `Pipe` are
    // `Sendable` on macOS 26+ so the cross-actor sharing is checked
    // by the compiler. `terminate()` is safe to call from any actor
    // while `run()` is in flight on another — `Process` runs its
    // child-process bookkeeping on an internal dispatch queue.
    let process = Process()
    let stderrPipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = cwd
    // Prefix every positional with `./` so Info-ZIP's option
    // scanner never sees a leading `-`: a single-source compress
    // of `-foo.txt` produces archive `-foo.txt.zip`, and either
    // arg fed bare would land in zip's flag pass as e.g. `-tt`.
    // The `--` end-of-options marker doesn't help here — Info-ZIP
    // explicitly rejects `--` before the archive name. `./`
    // prefixes are normalised out of the resulting entry names,
    // so the archive's directory layout is unchanged.
    let archiveArg = "./" + archiveName
    let sourceArgs = relativeNames.map { "./" + $0 }
    // `-b <dir>` redirects Info-ZIP's `ziXXXXXX` temp file out of
    // the cwd. Without it, zip(1) creates the temp archive next to
    // the final destination and the user sees a stray random-name
    // file in the finder pane until the rename at the end. Using
    // the per-user temp dir keeps the temp invisible; the final
    // archive still lands in cwd via zip's own rename. If the rename
    // crosses APFS containers (cwd on an external volume, temp on
    // the system disk) zip falls back to copy+delete — slower than
    // an in-place rename, but still correct.
    process.arguments = [
      "-b", NSTemporaryDirectory(), "-r", "-q", archiveArg,
    ] + sourceArgs
    // Capture stderr so partial-failure messages don't drop into
    // /dev/null with `-q` set — they go to the unified log instead
    // when zip exits non-zero.
    process.standardError = stderrPipe

    let opID = FinderOperationTracker.OperationID()
    let displayLabel = "Compressing “\(archiveName)”"
    FinderOperationTracker.shared.register(
      .init(
        id: opID,
        label: displayLabel,
        targetURLs: [archiveURL],
        cancel: { process.terminate() }))
    OperationsProgressPanel.scheduleShowIfNeeded(near: window)

    Task.detached(priority: .userInitiated) {
      defer {
        // `defer` runs synchronously off-main; the unregister must
        // hit the tracker on MainActor, so spawn a child Task that
        // hops over. Multiple ops finishing in the same turn each
        // enqueue their own hop — the order can differ from start
        // order, but `dismissIfEmpty`'s `Self.shared = nil` guard
        // tolerates the duplicate close-attempt path.
        Task { @MainActor in
          FinderOperationTracker.shared.unregister(opID)
          OperationsProgressPanel.dismissIfEmpty()
        }
      }
      do {
        try process.run()
      } catch {
        logger.error(
          "Compress \(archiveURL.path, privacy: .public) failed to launch: \(error.localizedDescription, privacy: .public)"
        )
        return
      }
      // Drain stderr *before* `waitUntilExit` so a flood of warnings
      // (per-file `could not open for reading` messages, say) can't
      // fill the pipe buffer and stall zip(1) on a blocking write.
      // `readDataToEndOfFile` returns when the write end closes —
      // i.e. when zip has exited — so `waitUntilExit` immediately
      // afterwards is effectively just a status fetch.
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      let status = process.terminationStatus
      if status != 0 {
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        logger.error(
          "Compress \(archiveURL.path, privacy: .public) exited with status \(status): \(stderr, privacy: .public)"
        )
      }
      // Even on a non-zero exit, zip(1) may have produced a usable
      // archive (status 12 = nothing to do, 18 = some files
      // unreadable). Surface the file in the table when it actually
      // exists so the user can inspect or delete it, instead of
      // silently strand the partial. A user-driven cancel via the
      // progress panel calls `terminate()` mid-stream, which leaves
      // a partial archive on disk; we still surface it so the user
      // can inspect / delete rather than wonder where the file went.
      let archiveExists = FileManager.default.fileExists(
        atPath: archiveURL.path(percentEncoded: false))
      guard archiveExists else { return }
      await MainActor.run { [weak self] in
        // No `FinderUndoCenter` registration here — system Finder
        // also leaves Compress out of its undo stack, since the
        // archive is a brand-new file alongside the originals
        // (nothing was destroyed) and ⌘⌫ trashes it just as
        // easily. Registering would only crowd the stack with an
        // entry users don't expect to walk back through.
        self?.finishCopyBatch(targets: [archiveURL])
      }
    }
  }

  /// Resolve the ZIP destination URL for `sources`, applying Finder's
  /// `<stem> N.zip` collision escalation. The stem is the single
  /// source's full last-component (extension included) for a single
  /// selection, or the literal `Archive` for any multi-selection.
  private func compressTargetURL(for sources: [URL]) -> URL {
    let stem = sources.count == 1 ? sources[0].lastPathComponent : "Archive"
    let fm = FileManager.default
    var candidate = currentURL.appendingPathComponent("\(stem).zip")
    if !fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
      return candidate
    }
    var n = 2
    while true {
      candidate = currentURL.appendingPathComponent("\(stem) \(n).zip")
      if !fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
        return candidate
      }
      n += 1
    }
  }
}
