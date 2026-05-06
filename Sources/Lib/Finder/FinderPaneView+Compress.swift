import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderPane")

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
    let urls = tableView.selectedRowIndexes.compactMap { idx -> URL? in
      idx < items.count ? items[idx].url : nil
    }
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

    // Once dispatched, the zip subprocess runs to completion even if
    // the pane closes mid-archive: there is no `Task.cancel` path
    // wired here. Killing zip(1) mid-stream would leave a partial
    // archive on disk for the user to clean up, which is worse than
    // letting it finish — Finder's cancel button is paired with a
    // progress sheet that's outside this commit's scope.
    Task.detached(priority: .userInitiated) {
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
      process.arguments = ["-r", "-q", archiveArg] + sourceArgs
      // Capture stderr so partial-failure messages don't drop into
      // /dev/null with `-q` set — they go to the unified log instead
      // when zip exits non-zero.
      process.standardError = stderrPipe
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
      // silently strand the partial.
      let archiveExists = FileManager.default.fileExists(
        atPath: archiveURL.path(percentEncoded: false))
      guard archiveExists else { return }
      await MainActor.run { [weak self] in
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
