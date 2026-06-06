import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FinderPane")

/// Drag source and drop destination for finder panes. Both list and
/// icon modes share the validate / accept core via the helpers
/// `validateDropOperation(sources:destination:)` and
/// `performDrop(sources:destination:op:sourcePane:)`; the per-mode
/// delegate methods only resolve the destination URL from their
/// presentation-specific row / index path argument and forward to
/// the shared core.
///
/// Source side: returning an `NSURL` from
/// `pasteboardWriterForRow:` / `pasteboardWriterForItemAt:` is the
/// entire contract — AppKit auto-handles the multi-row case (each
/// selected row's writer is collected into one pasteboard), the
/// mouse-threshold gesture that starts the drag, and the system drop
/// animations. Recipients that accept `.fileURL` (Finder, editors,
/// Dock, other e05 panes) receive the selection as file references.
///
/// Destination side: `validateDrop:` advertises the operation that
/// matches the source/destination volumes — `.move` within a volume,
/// `.copy` across volumes — so the drag image's `+` overlay tells the
/// user up-front when a copy will happen instead of a move (Finder's
/// convention). Self-drops and descendant drops are rejected before
/// any move is attempted. `acceptDrop:` performs the announced
/// operation and falls back to copy if `moveItem` still surfaces an
/// `EXDEV` (e.g. an external volume unmounts between validate and
/// accept). Directory monitor coalesces the resulting reload into
/// its debounce window, so no manual reload call is needed here.
extension FinderPaneView {
  // MARK: - List drag source

  public func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
    -> NSPasteboardWriting?
  {
    guard row >= 0, row < items.count else { return nil }
    return items[row].url as NSURL
  }

  // MARK: - List drop target

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

    guard let op = validateDropOperation(sources: sources, destination: destURL) else {
      return []
    }

    // AppKit funnels both inter-row gaps and the empty area below the
    // last row into `.above`, so a single check covers both — the
    // table's own per-row highlight is wrong for either case, repaint
    // it as a whole-pane highlight instead.
    if dropOperation == .above {
      tableView.setDropRow(-1, dropOperation: .above)
    }

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
    guard let destURL = resolveDropDestination(row: row, dropOperation: dropOperation) else {
      return false
    }

    let op = Self.dropOperation(sources: sources, destination: destURL)
    let sourcePane = Self.resolveDragSourcePane(from: info)
    return performDrop(
      sources: sources, destination: destURL, op: op, sourcePane: sourcePane)
  }

  // MARK: - Icon drag source

  public func collectionView(
    _ collectionView: NSCollectionView,
    pasteboardWriterForItemAt indexPath: IndexPath
  ) -> (any NSPasteboardWriting)? {
    guard indexPath.item < items.count else { return nil }
    return items[indexPath.item].url as NSURL
  }

  public func collectionView(
    _ collectionView: NSCollectionView,
    draggingSession session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    [.move, .copy]
  }

  // MARK: - Icon drop target

  public func collectionView(
    _ collectionView: NSCollectionView,
    validateDrop draggingInfo: any NSDraggingInfo,
    proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
    dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
  ) -> NSDragOperation {
    let sources = draggedURLs(from: draggingInfo)
    guard !sources.isEmpty else { return [] }
    let proposedItem = proposedIndexPath.pointee.item
    guard
      let destURL = resolveIconDropDestination(
        proposedItem: proposedItem, dropOperation: dropOperation.pointee)
    else { return [] }
    guard let op = validateDropOperation(sources: sources, destination: destURL) else {
      return []
    }
    return op
  }

  public func collectionView(
    _ collectionView: NSCollectionView,
    acceptDrop draggingInfo: any NSDraggingInfo,
    indexPath: IndexPath,
    dropOperation: NSCollectionView.DropOperation
  ) -> Bool {
    let sources = draggedURLs(from: draggingInfo)
    guard !sources.isEmpty else { return false }
    guard
      let destURL = resolveIconDropDestination(
        proposedItem: indexPath.item, dropOperation: dropOperation)
    else { return false }
    let op = Self.dropOperation(sources: sources, destination: destURL)
    let sourcePane = Self.resolveDragSourcePane(from: draggingInfo)
    return performDrop(
      sources: sources, destination: destURL, op: op, sourcePane: sourcePane)
  }

  // MARK: - Shared validate / accept core

  /// Reject no-op / invalid drops, then resolve the drag operation
  /// (move within volume, copy across volumes). A drop is rejected
  /// (returns `nil`) when a source *is* the destination, when the
  /// destination sits inside a source (descendant), or when a source
  /// already lives directly in the destination — dropping a file back
  /// into its own folder moves nothing, so it is a no-op rather than a
  /// spurious "already exists" conflict (Finder's behaviour).
  /// `validateDrop` callers translate `nil` into the empty
  /// `NSDragOperation`.
  private func validateDropOperation(
    sources: [URL], destination destURL: URL
  ) -> NSDragOperation? {
    let destPath = Self.normalizedPath(destURL)
    for src in sources {
      let srcPath = Self.normalizedPath(src)
      if srcPath == destPath { return nil }
      if destPath.hasPrefix(srcPath + "/") { return nil }
      // Source already in the destination: the move resolves to the
      // file's current path, so performDrop's conflict probe would
      // match the file against itself and pop an "already exists"
      // dialog for a move that does nothing. Reject as a no-op.
      if Self.normalizedPath(src.deletingLastPathComponent()) == destPath {
        return nil
      }
    }
    return Self.dropOperation(sources: sources, destination: destURL)
  }

  /// Execute the drop. Detects conflicts and runs the resolution
  /// alert (single batch decision applied to every conflicting
  /// source), performs each per-source `moveItem` / `copyItem`,
  /// falls back to copy on cross-volume race, and registers the
  /// successfully-moved pairs with the undo manager. Returns
  /// `true` when at least one source landed on the destination so
  /// AppKit dismisses the drop animation correctly. Shared between
  /// the list and icon entry points; behaviour is identical
  /// regardless of which presentation drove the call.
  private func performDrop(
    sources: [URL], destination destURL: URL, op: NSDragOperation,
    sourcePane: FinderPaneView?
  ) -> Bool {
    let fm = FileManager.default

    // Resolve every source's conflict (target path occupied) up front
    // so the user is asked exactly once per drop. The chosen
    // resolution applies batch-wide — Finder's per-conflict prompt
    // chain is more flexible but requires N round-trips through the
    // alert sheet, which interrupts a drag flow. A single batch
    // decision matches what most users want for "I dropped a folder
    // and a few file names happen to collide".
    let plans = sources.map { src in
      (source: src, target: destURL.appendingPathComponent(src.lastPathComponent))
    }
    let conflicts = plans.filter {
      fm.fileExists(atPath: $0.target.path(percentEncoded: false))
    }
    let resolution: ConflictResolution
    if conflicts.isEmpty {
      resolution = .proceed
    } else {
      resolution = presentConflictAlert(
        conflictCount: conflicts.count,
        firstName: conflicts[0].target.lastPathComponent)
    }
    guard resolution != .stop else { return false }

    var succeeded = 0
    // Track only `.move` successes — cross-volume `copyItem` results
    // are deliberately not registered with the undo manager. System
    // Finder treats those copies the same way (no undo entry) since
    // the source is still on disk; ⌘⌫ on the copy is the obvious
    // recovery path.
    var movePairs: [(origin: URL, destination: URL)] = []
    for plan in plans {
      let hasConflict =
        fm.fileExists(atPath: plan.target.path(percentEncoded: false))
      var actualTarget = plan.target
      if hasConflict {
        switch resolution {
        case .replace:
          // Send the existing target to Trash so the user can still
          // recover it from `~/.Trash`. The trashed file is
          // intentionally not registered with the undo manager — ⌘Z
          // reverses the move only, leaving the trashed original in
          // Trash for the user to inspect or restore manually. Same
          // semantics as system Finder's Replace. The `resultingItemURL`
          // out-param is required by the signature but the actual
          // trash URL isn't needed downstream.
          do {
            try fm.trashItem(at: plan.target, resultingItemURL: nil)
          } catch {
            logger.error(
              "Drop replace: trash existing target \(plan.target.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            continue
          }
        case .keepBoth:
          // Number-suffix the new target (`README 2.md`) — Finder's
          // Keep Both convention for cross-directory drops. The
          // ` copy` suffix that `availableCopyURL` produces is
          // reserved for ⌘D Duplicate where the verb makes that
          // suffix natural.
          let stem = plan.target.deletingPathExtension().lastPathComponent
          let ext = plan.target.pathExtension
          actualTarget = availableNumberedURL(in: destURL, stem: stem, ext: ext)
        case .proceed, .stop:
          break
        }
      }
      if op == .copy {
        do {
          try fm.copyItem(at: plan.source, to: actualTarget)
          succeeded += 1
        } catch {
          logger.error(
            "Drop copy failed \(plan.source.path, privacy: .public) → \(actualTarget.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
        continue
      }
      do {
        try fm.moveItem(at: plan.source, to: actualTarget)
        succeeded += 1
        movePairs.append((plan.source, actualTarget))
      } catch let error as NSError where Self.isCrossVolumeError(error) {
        // Validate said `.move`, but the source's volume disappeared
        // (or was reclassified) between validate and accept. Fall
        // back to copy so the drop completes instead of evaporating.
        // The fallback isn't appended to `movePairs` either —
        // cross-volume copies are intentionally not registered with
        // the undo manager, same as the explicit `.copy` branch
        // above.
        do {
          try fm.copyItem(at: plan.source, to: actualTarget)
          succeeded += 1
        } catch {
          logger.error(
            "Cross-volume copy failed \(plan.source.path, privacy: .public) → \(actualTarget.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      } catch {
        logger.error(
          "Drop move failed \(plan.source.path, privacy: .public) → \(actualTarget.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    if !movePairs.isEmpty {
      FinderUndoCenter.registerMove(
        pairs: movePairs, sourcePane: sourcePane, in: self)
    }
    // Surface a per-batch error toast when any source failed to land.
    // A live drop posts no success toast (matching Finder), so this is
    // the only feedback for a partial / full failure; per-item causes
    // are already logged above. `actionName: nil` — there is no
    // companion success line to name.
    let failed = plans.count - succeeded
    if failed > 0 {
      let verbPhrase = op == .copy ? "copied" : "moved"
      let message = FinderUndoCenter.partialFailureMessage(
        actionName: nil, succeeded: succeeded, total: plans.count, verbPhrase: verbPhrase)
      if let container = window?.contentViewController as? PaneContainerViewController {
        container.showToast(message, style: .error)
      } else {
        logger.error(
          "Drop failure toast dropped: container unresolved (\(message, privacy: .public))")
      }
    }
    return succeeded > 0
  }

  /// Three-way batch decision a drop's conflicting targets resolve
  /// to. `.proceed` is the no-conflicts fast path — kept in the
  /// enum so the per-source loop has a single value to switch on
  /// regardless of whether any conflicts were detected.
  private enum ConflictResolution {
    case proceed
    case replace
    case keepBoth
    case stop
  }

  /// Modal alert that asks the user which conflict resolution the
  /// drop should use. Sync `runModal` is intentional — the drop is
  /// already in flight on the main run loop, and a sheet would
  /// require restructuring `acceptDrop` to a deferred completion
  /// shape that AppKit's drag machinery doesn't naturally hand
  /// back. The text mirrors Finder's wording so users transferring
  /// from system Finder don't have to re-learn the dialog.
  /// `firstName` is consumed only on the single-conflict path; the
  /// multi-conflict path uses the count alone, matching Finder.
  private func presentConflictAlert(
    conflictCount: Int, firstName: String
  ) -> ConflictResolution {
    let alert = NSAlert()
    alert.alertStyle = .warning
    if conflictCount == 1 {
      alert.messageText =
        "An item named “\(firstName)” already exists in this location."
      alert.informativeText =
        "Do you want to replace it with the one you're moving?"
    } else {
      alert.messageText =
        "\(conflictCount) items with the same names already exist in this location."
      alert.informativeText =
        "Do you want to replace them with the ones you're moving? The choice applies to all \(conflictCount) conflicts; non-conflicting entries proceed as usual."
    }
    alert.addButton(withTitle: "Replace")
    alert.addButton(withTitle: "Keep Both")
    let stopButton = alert.addButton(withTitle: "Stop")
    // Wire ESC to Stop so the keyboard cancel matches the
    // system-default destructive-alert dismissal.
    stopButton.keyEquivalent = "\u{1b}"
    let response = alert.runModal()
    switch response {
    case .alertFirstButtonReturn: return .replace
    case .alertSecondButtonReturn: return .keepBoth
    case .alertThirdButtonReturn: return .stop
    default: return .stop
    }
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

  /// Icon-mode counterpart of `resolveDropDestination`. The collection
  /// view's `.on` aimed at a directory cell drops into that cell;
  /// `.on` aimed at a file/package cell is rejected; `.before`
  /// (gap drop, including the empty area at the end of the grid)
  /// drops into the pane's cwd. Out-of-range items collapse to cwd.
  func resolveIconDropDestination(
    proposedItem: Int, dropOperation: NSCollectionView.DropOperation
  ) -> URL? {
    if dropOperation == .on, proposedItem >= 0, proposedItem < items.count {
      let item = items[proposedItem]
      if item.isDirectory && !item.isPackage {
        return item.url
      }
      return nil
    }
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

  /// Map a dragging session's originating view back to the owning
  /// finder pane, regardless of which presentation drove the drag.
  /// External drags (system Finder, editors, Dock) leave
  /// `draggingSource` as something we don't recognise — return `nil`
  /// so the undo registration falls back to "no in-app source pane to
  /// refresh".
  static func resolveDragSourcePane(from info: any NSDraggingInfo) -> FinderPaneView? {
    if let table = info.draggingSource as? FinderTableView {
      return table.enclosingFinderPane
    }
    if let icon = info.draggingSource as? FinderIconCollectionView {
      return icon.enclosingFinderPane
    }
    return nil
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
