import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderPane")

/// Drag source and drop destination for finder panes.
///
/// Source side: returning an `NSURL` from `pasteboardWriterForRow:` is
/// the entire contract — AppKit auto-handles the multi-row case (each
/// selected row's writer is collected into one pasteboard), the
/// mouse-threshold gesture that starts the drag, and the system drop
/// animations. Recipients that accept `.fileURL` (Finder, editors,
/// Dock, other e05 panes) receive the selection as file references.
///
/// Destination side: `validateDrop:` advertises the operation that
/// matches the source/destination volumes — `.move` within a volume,
/// `.copy` across volumes — so the drag image's `+` overlay tells the
/// user up-front when a copy will happen instead of a move (Finder's
/// list-view convention). Self-drops and descendant drops are
/// rejected before any move is attempted. `acceptDrop:` performs the
/// announced operation and falls back to copy if `moveItem` still
/// surfaces an `EXDEV` (e.g. an external volume unmounts between
/// validate and accept). Directory monitor coalesces the resulting
/// reload into its debounce window, so no manual reload call is
/// needed here.
extension FinderPaneView {
  // MARK: - Drag source

  public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
    guard row >= 0, row < items.count else { return nil }
    return items[row].url as NSURL
  }

  // MARK: - Drop target

  public func tableView(
    _ tableView: NSTableView,
    validateDrop info: NSDraggingInfo,
    proposedRow row: Int,
    proposedDropOperation dropOperation: NSTableView.DropOperation
  ) -> NSDragOperation {
    let sources = draggedURLs(from: info)
    logger.debug(
      "validateDrop row=\(row, privacy: .public) op=\(dropOperation.rawValue, privacy: .public) sources=\(sources.count, privacy: .public)"
    )
    guard !sources.isEmpty else {
      logger.debug("validateDrop reject: no .fileURL on pasteboard")
      return []
    }
    guard let destURL = resolveDropDestination(row: row, dropOperation: dropOperation) else {
      logger.debug("validateDrop reject: destination unresolved (file row drop)")
      return []
    }

    let destPath = Self.normalizedPath(destURL)
    for src in sources {
      let srcPath = Self.normalizedPath(src)
      if srcPath == destPath {
        logger.debug(
          "validateDrop reject: self-drop src=\(srcPath, privacy: .public)"
        )
        return []
      }
      if destPath.hasPrefix(srcPath + "/") {
        logger.debug(
          "validateDrop reject: descendant drop src=\(srcPath, privacy: .public) dest=\(destPath, privacy: .public)"
        )
        return []
      }
    }

    // AppKit funnels both inter-row gaps and the empty area below the
    // last row into `.above`, so a single check covers both — the
    // table's own per-row highlight is wrong for either case, repaint
    // it as a whole-pane highlight instead.
    if dropOperation == .above {
      tableView.setDropRow(-1, dropOperation: .above)
    }

    let op = Self.dropOperation(sources: sources, destination: destURL)
    logger.debug("validateDrop accept: \(op.rawValue, privacy: .public)")
    return op
  }

  public func tableView(
    _ tableView: NSTableView,
    acceptDrop info: NSDraggingInfo,
    row: Int,
    dropOperation: NSTableView.DropOperation
  ) -> Bool {
    let sources = draggedURLs(from: info)
    guard !sources.isEmpty else { return false }
    guard let destURL = resolveDropDestination(row: row, dropOperation: dropOperation) else { return false }

    let op = Self.dropOperation(sources: sources, destination: destURL)
    let fm = FileManager.default
    var anyAccepted = false
    // Track only `.move` successes — cross-volume `copyItem` results
    // are deliberately not registered with the undo manager. System
    // Finder treats those copies the same way (no undo entry) since
    // the source is still on disk; ⌘⌫ on the copy is the obvious
    // recovery path.
    var movePairs: [(origin: URL, destination: URL)] = []
    for src in sources {
      let target = destURL.appendingPathComponent(src.lastPathComponent)
      if op == .copy {
        do {
          try fm.copyItem(at: src, to: target)
          anyAccepted = true
        } catch {
          logger.error(
            "Drop copy failed \(src.path, privacy: .public) → \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
        continue
      }
      do {
        try fm.moveItem(at: src, to: target)
        anyAccepted = true
        movePairs.append((src, target))
      } catch let error as NSError where Self.isCrossVolumeError(error) {
        // Validate said `.move`, but the source's volume disappeared
        // (or was reclassified) between validate and accept. Fall
        // back to copy so the drop completes instead of evaporating.
        // The fallback isn't appended to `movePairs` either —
        // cross-volume copies are intentionally not registered with
        // the undo manager, same as the explicit `.copy` branch
        // above.
        do {
          try fm.copyItem(at: src, to: target)
          anyAccepted = true
        } catch {
          logger.error(
            "Cross-volume copy failed \(src.path, privacy: .public) → \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      } catch {
        logger.error(
          "Drop move failed \(src.path, privacy: .public) → \(target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    if !movePairs.isEmpty {
      FinderUndoCenter.registerMove(pairs: movePairs, in: self)
    }
    return anyAccepted
  }

  // MARK: - Drop helpers

  private func resolveDropDestination(row: Int, dropOperation: NSTableView.DropOperation) -> URL? {
    if dropOperation == .on, row >= 0, row < items.count {
      let item = items[row]
      if item.isDirectory && !item.isPackage {
        return item.url
      }
      // `.on` aimed at a file or package row: rejected. The user
      // clearly meant "into this row", so collapsing onto its parent
      // would be misleading.
      return nil
    }
    // `.above` (between rows or below the last row), or `.on` with an
    // out-of-range row: drop into the pane's cwd.
    return currentURL
  }

  /// Bridge `NSURL` → `URL` element-wise; the array-level cast
  /// `[NSURL] as? [URL]` only succeeds through Foundation's
  /// conditional collection bridge and silently fails on a single
  /// non-bridgeable element, which would surface here as a phantom
  /// "no .fileURL on pasteboard" reject log.
  private func draggedURLs(from info: NSDraggingInfo) -> [URL] {
    let raw = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) ?? []
    return raw.compactMap { ($0 as? NSURL) as URL? }
  }

  /// `.copy` when any source lives on a different volume than the
  /// destination, otherwise `.move` — matches Finder list-view's
  /// drag image overlay (the `+` badge tells the user a copy is
  /// about to happen) and avoids the validate/accept lying to each
  /// other about move semantics.
  private static func dropOperation(sources: [URL], destination: URL) -> NSDragOperation {
    let destVolume = volumeIdentifier(of: destination)
    for src in sources {
      if volumeIdentifier(of: src) != destVolume {
        return .copy
      }
    }
    return .move
  }

  private static func volumeIdentifier(of url: URL) -> AnyHashable? {
    let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
    return values?.volumeIdentifier as? AnyHashable
  }

  /// Strip trailing `/` so directory and file paths share a single
  /// canonical form. `URL.path(percentEncoded:)` keeps the trailing
  /// slash that the generated RFC 3986 path carries for directory
  /// URLs (macOS 13+), which would otherwise break the descendant
  /// check (`destPath.hasPrefix(srcPath + "/")` reads `src//` when
  /// `srcPath` already ends in `/`).
  private static func normalizedPath(_ url: URL) -> String {
    let raw = url.resolvingSymlinksInPath().path(percentEncoded: false)
    if raw.count > 1, raw.hasSuffix("/") {
      return String(raw.dropLast())
    }
    return raw
  }

  /// Cross-device link (`EXDEV` = 18) means `moveItem` tried to
  /// straddle two filesystems. FileManager surfaces the condition
  /// either directly in `NSPOSIXErrorDomain` or wrapped under
  /// `NSUnderlyingErrorKey`; catch both shapes.
  private static func isCrossVolumeError(_ error: NSError) -> Bool {
    let exdev = 18
    if error.domain == NSPOSIXErrorDomain, error.code == exdev { return true }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain, underlying.code == exdev
    {
      return true
    }
    return false
  }
}
