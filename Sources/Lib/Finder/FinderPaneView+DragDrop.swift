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
/// convention). Holding Option forces a copy and Option-Command makes an
/// alias, read live so the badge tracks the keys as they are pressed.
/// A drop is refused with the not-allowed cursor only when it is
/// structurally impossible — every source is a self-drop or a descendant
/// drop. A same-folder move is accepted but does nothing (Finder leaves
/// the file in place), a same-folder copy / alias makes a `… copy` /
/// `… alias` sibling, and a `.on` drop onto a file lands in the enclosing
/// folder. `acceptDrop:` performs the announced
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

  /// An empty drag operation paired with an explicit not-allowed cursor.
  /// AppKit does not reliably draw the no-drop "✖" for an intra-app
  /// table / collection drag that returns an empty operation: a valid
  /// copy / alias still shows its badge, but a rejected target keeps the
  /// neutral cursor instead of signalling that the drop won't land. Set
  /// the cursor here on every reject; moving onto a valid target next
  /// returns a real operation and AppKit restores the move / copy / alias
  /// cursor over it.
  private func rejectDrop() -> NSDragOperation {
    NSCursor.operationNotAllowed.set()
    return []
  }

  // MARK: - List drop target

  public func tableView(
    _ tableView: NSTableView,
    validateDrop info: NSDraggingInfo,
    proposedRow row: Int,
    proposedDropOperation dropOperation: NSTableView.DropOperation
  ) -> NSDragOperation {
    let sources = draggedURLs(from: info)
    guard !sources.isEmpty else { return rejectDrop() }

    // Resolve the destination from the row physically under the cursor
    // rather than AppKit's proposed row / operation. A folder row is a
    // drop *into* that folder; anything else (a file row, an inter-row
    // gap, the empty area) drops into the cwd. This makes hovering a
    // dragged folder's own row a self-drop (→ reject + ✖) instead of
    // AppKit's silent reorder proposal, and stops a file row from being
    // highlighted as if the drop were landing on it.
    let point = tableView.convert(info.draggingLocation, from: nil)
    let hitRow = tableView.row(at: point)
    let overFolder =
      hitRow >= 0 && hitRow < items.count
      && items[hitRow].isDirectory && !items[hitRow].isPackage
    let destURL = overFolder ? items[hitRow].url : currentURL

    guard let op = validateDropOperation(sources: sources, destination: destURL) else {
      return rejectDrop()
    }

    // Highlight the target folder's row for an into-folder drop, the
    // whole pane otherwise (the table's own per-row highlight would
    // wrongly point at a file row that really drops into the cwd).
    tableView.setDropRow(
      overFolder ? hitRow : -1, dropOperation: overFolder ? .on : .above)
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

    let op = modifierDropOperation(sources: sources, destination: destURL)
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
    // `.link` is required for Option-Command alias drops: the collection
    // view intersects this mask with the destination's validateDrop
    // result, so omitting it would zero out an alias drop and reject it.
    [.move, .copy, .link]
  }

  // MARK: - Icon drop target

  public func collectionView(
    _ collectionView: NSCollectionView,
    validateDrop draggingInfo: any NSDraggingInfo,
    proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
    dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
  ) -> NSDragOperation {
    let sources = draggedURLs(from: draggingInfo)
    guard !sources.isEmpty else { return rejectDrop() }

    // Resolve from the cell physically under the cursor (mirrors the
    // list path): a folder cell is a drop into it; anything else drops
    // into the cwd. Hovering a dragged folder's own cell becomes a
    // self-drop (→ reject + ✖) instead of a silent gap proposal, and no
    // file cell is highlighted for a drop that lands in the cwd.
    let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
    let hitItem = collectionView.indexPathForItem(at: point)?.item
    let folderItem = hitItem.flatMap { item -> Int? in
      item >= 0 && item < items.count && items[item].isDirectory
        && !items[item].isPackage ? item : nil
    }
    let destURL = folderItem.map { items[$0].url } ?? currentURL

    guard let op = validateDropOperation(sources: sources, destination: destURL) else {
      return rejectDrop()
    }

    if let folderItem {
      proposedIndexPath.pointee = IndexPath(item: folderItem, section: 0) as NSIndexPath
      dropOperation.pointee = .on
    } else {
      proposedIndexPath.pointee = IndexPath(item: items.count, section: 0) as NSIndexPath
      dropOperation.pointee = .before
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
    let op = modifierDropOperation(sources: sources, destination: destURL)
    let sourcePane = Self.resolveDragSourcePane(from: draggingInfo)
    return performDrop(
      sources: sources, destination: destURL, op: op, sourcePane: sourcePane)
  }

  // MARK: - Shared validate / accept core

  /// Resolve the drag operation (move within volume, copy across
  /// volumes) for the sources that can actually land on `destURL`.
  /// Returns `nil` — which `validateDrop` callers translate into the
  /// empty `NSDragOperation` — only when *every* source is a no-op /
  /// invalid one, so a drag mixing one bad item with several good ones
  /// still validates and the good ones move (Finder's partial accept).
  private func validateDropOperation(
    sources: [URL], destination destURL: URL
  ) -> NSDragOperation? {
    let acceptable = Self.acceptableDropSources(sources, destination: destURL)
    guard !acceptable.isEmpty else { return nil }
    return modifierDropOperation(sources: acceptable, destination: destURL)
  }

  /// The drop operation the held modifier keys ask for, matching
  /// Finder's Option = copy and Option-Command = alias. Read live from
  /// `NSEvent.modifierFlags` so the operation — and the drag image's
  /// badge — tracks the keys held at this instant; validateDrop and
  /// acceptDrop both consult it so the announced and performed
  /// operations agree. Anything else, Command alone included, falls back
  /// to the volume-based default (Finder's Command force-move isn't
  /// wired yet).
  private func modifierDropOperation(
    sources: [URL], destination destURL: URL
  ) -> NSDragOperation {
    let mods = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
    if mods.contains(.option), mods.contains(.command) { return .link }
    if mods.contains(.option) { return .copy }
    return Self.dropOperation(sources: sources, destination: destURL)
  }

  /// The subset of `sources` whose drop onto `destURL` is structurally
  /// possible: everything except a source that *is* the destination
  /// (self-drop) or a destination sitting inside a source (descendant).
  /// Those two are impossible for any operation, so a drag made up
  /// entirely of them is refused with the not-allowed cursor. Everything
  /// else is "droppable" and keeps a normal cursor — including a
  /// same-folder move, which Finder accepts and silently leaves in place
  /// rather than rejecting; `performDrop` skips that no-op. The excluded
  /// sources are same-volume as the destination by construction (they sit
  /// at / in / around it), so dropping them never changes the
  /// move-vs-copy decision for the remaining sources.
  private static func acceptableDropSources(
    _ sources: [URL], destination destURL: URL
  ) -> [URL] {
    let destPath = normalizedPath(destURL)
    return sources.filter { src in
      let srcPath = normalizedPath(src)
      if srcPath == destPath { return false }
      if destPath.hasPrefix(srcPath + "/") { return false }
      return true
    }
  }

  /// The path a dropped source should occupy under `op`. A cross-folder
  /// drop keeps the source's own name (any collision is resolved by the
  /// dialog in `performDrop`). A same-folder copy or alias — reachable
  /// only because `acceptableDropSources` lets those through — instead
  /// auto-suffixes to a free `… copy` / `… alias` sibling so it never
  /// collides with the source it sits beside, matching Duplicate and Make
  /// Alias. A move never reaches the same-folder branch (it is filtered
  /// out as a no-op upstream).
  private func dropTarget(
    for src: URL, op: NSDragOperation, destination destURL: URL
  ) -> URL {
    let sameFolder =
      Self.normalizedPath(src.deletingLastPathComponent())
      == Self.normalizedPath(destURL)
    guard sameFolder else {
      return destURL.appendingPathComponent(src.lastPathComponent)
    }
    if op == .copy {
      return availableCopyURL(
        in: destURL,
        stem: src.deletingPathExtension().lastPathComponent,
        ext: src.pathExtension)
    }
    if op == .link {
      return aliasTargetURL(for: src)
    }
    return destURL.appendingPathComponent(src.lastPathComponent)
  }

  /// Execute the drop. On the main actor: filter to the actionable
  /// sources, run the conflict-resolution alert (one batch decision for
  /// every collision) and resolve each plan into a final target. The
  /// per-source `moveItem` / `copyItem` / alias work then runs off the
  /// main actor in `runDropBatch` so a large or cross-volume drop doesn't
  /// freeze the window. Returns `true` once the batch is launched (or the
  /// drop is a deliberate no-op) so AppKit dismisses the drag; per-item
  /// failures surface later through a toast. Shared between the list and
  /// icon entry points.
  private func performDrop(
    sources: [URL], destination destURL: URL, op: NSDragOperation,
    sourcePane: FinderPaneView?
  ) -> Bool {
    let fm = FileManager.default

    // Drop the structurally-impossible sources (self, descendant); the
    // pasteboard is re-read on accept so re-filter to match validateDrop.
    let acceptable = Self.acceptableDropSources(sources, destination: destURL)
    guard !acceptable.isEmpty else { return false }

    // A same-folder move does nothing — the source is already here.
    // Finder accepts the drop and leaves it in place rather than popping
    // a self-conflict dialog, so skip those from the action while still
    // reporting success so the drag doesn't bounce. A same-folder copy /
    // alias is NOT skipped: it makes a `… copy` / `… alias` sibling.
    let actionable = acceptable.filter { src in
      !(op == .move
        && Self.normalizedPath(src.deletingLastPathComponent())
          == Self.normalizedPath(destURL))
    }
    guard !actionable.isEmpty else { return true }

    // Resolve every source's conflict (target path occupied) up front
    // so the user is asked exactly once per drop. The chosen
    // resolution applies batch-wide — Finder's per-conflict prompt
    // chain is more flexible but requires N round-trips through the
    // alert sheet, which interrupts a drag flow. A single batch
    // decision matches what most users want for "I dropped a folder
    // and a few file names happen to collide".
    let plans = actionable.map { src in
      (source: src, target: dropTarget(for: src, op: op, destination: destURL))
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
    // Resolve each plan against the conflict decision into a flat list
    // for the off-main batch. Keep Both's free-slot numbering runs here
    // (cheap `fileExists` probes); Replace defers the existing item's
    // trash into the batch so a folder full of replacements doesn't block
    // the main actor either. Stop drops the conflicting plans entirely —
    // the non-conflicting sources still move.
    var execPlans: [DropPlan] = []
    // Targets already claimed by earlier plans. The batch writes nothing
    // until every target is resolved here, so without tracking these a
    // Keep Both of two same-named sources would number both to the same
    // free slot and the second would fail against the first on disk.
    var reserved: Set<URL> = []
    for plan in plans {
      let hasConflict =
        fm.fileExists(atPath: plan.target.path(percentEncoded: false))
      guard hasConflict else {
        execPlans.append(
          .init(source: plan.source, target: plan.target, replaceExisting: false))
        reserved.insert(plan.target)
        continue
      }
      switch resolution {
      case .replace:
        execPlans.append(
          .init(source: plan.source, target: plan.target, replaceExisting: true))
        reserved.insert(plan.target)
      case .keepBoth:
        // Number-suffix the new target (`README 2.md`) — Finder's Keep
        // Both convention for cross-directory drops. The ` copy` suffix
        // `availableCopyURL` produces is reserved for ⌘D Duplicate.
        let stem = plan.target.deletingPathExtension().lastPathComponent
        let ext = plan.target.pathExtension
        let target = availableNumberedURL(
          in: destURL, stem: stem, ext: ext, reserved: reserved)
        execPlans.append(
          .init(source: plan.source, target: target, replaceExisting: false))
        reserved.insert(target)
      case .stop:
        continue
      case .proceed:
        // `.proceed` only arises with no conflicts, so a conflicting plan
        // never reaches here.
        execPlans.append(
          .init(source: plan.source, target: plan.target, replaceExisting: false))
        reserved.insert(plan.target)
      }
    }
    // Everything was Stopped (or filtered out): a deliberate no-op.
    // Report success so AppKit dismisses the drag instead of bouncing it
    // back to the source, matching Finder's Stop.
    guard !execPlans.isEmpty else { return true }

    runDropBatch(execPlans: execPlans, op: op, sourcePane: sourcePane)
    return true
  }

  /// One resolved drop action for the off-main batch: the source, its
  /// final on-disk target (already collision-numbered for Keep Both), and
  /// whether an existing item at the target must be trashed first
  /// (Replace). `Sendable` so the batch `Task` can carry the whole list
  /// across the actor hop.
  private struct DropPlan: Sendable {
    let source: URL
    let target: URL
    let replaceExisting: Bool
  }

  /// Run a resolved drop's move / copy / alias actions off the main
  /// actor, mirroring `runCopyBatch` so a several-hundred-file drag
  /// doesn't freeze the window — a same-volume move is instant, but a
  /// cross-volume copy or a large tree blocks until the bytes land. The
  /// conflict alert and Keep Both numbering already ran on the main actor
  /// in `performDrop`; this executes the per-plan filesystem work and,
  /// back on the main actor, registers the moves with the undo manager
  /// and surfaces a partial-failure toast. The op is registered with
  /// `FinderOperationTracker` so the progress panel and the dest pane's
  /// greyed placeholder rows appear while a slow batch runs. The panel's ✕
  /// flips a shared `CopyCancellationToken` the per-plan loop checks at each
  /// boundary and the off-main `copyfile` callback checks mid-file, so a
  /// cancel aborts even a single large cross-volume copy; the failure tally
  /// counts only the plans actually attempted, never the cancelled one.
  private func runDropBatch(
    execPlans: [DropPlan], op: NSDragOperation, sourcePane: FinderPaneView?
  ) {
    let opID = FinderOperationTracker.OperationID()
    let targets = execPlans.map { $0.target }
    let verbPhrase = Self.verbPhrase(for: op)
    // Shared with the cancel closure: the ✕ flips it, and the off-main
    // copyfile callback observes it to abort a cross-volume copy mid-file.
    let token = CopyCancellationToken()
    // Byte tally for the determinate progress bar — copy only; a move is an
    // instant rename and an alias a tiny bookmark write, neither worth a bar.
    let progress: FinderCopyProgress? = op == .copy ? FinderCopyProgress() : nil
    // Created before `register` so the cancel closure can capture it.
    let task = Task.detached(priority: .userInitiated) {
      defer {
        Task { @MainActor in
          FinderOperationTracker.shared.unregister(opID)
          OperationsProgressPanel.dismissIfEmpty()
        }
      }
      let fm = FileManager()
      // Preparing phase (copy only): tally each source's size so the bar has
      // a denominator (it sits at an empty determinate bar until the total
      // lands), then credit each plan's walked size as it finishes so a
      // clone — which streams no callback bytes — still drives it to 100%.
      // Parallel to `execPlans` when `progress` is set (op == .copy), empty
      // otherwise; `sizes[index]` is read only under `if let progress`, so
      // the index stays in range.
      let sizes: [Int64] =
        progress == nil ? [] : execPlans.map { Self.allocatedSize(of: $0.source) }
      progress?.setTotalBytes(sizes.reduce(0, +))
      var movePairs: [(origin: URL, destination: URL)] = []
      var succeeded = 0
      var attempted = 0
      planLoop: for (index, plan) in execPlans.enumerated() {
        if token.isCancelled { break }
        attempted += 1
        switch Self.executeDropPlan(
          plan, op: op, token: token, fm: fm, progress: progress)
        {
        case .succeeded(let movePair):
          succeeded += 1
          if let movePair { movePairs.append(movePair) }
          if let progress { progress.completePlan(bytes: sizes[index]) }
        case .cancelled:
          // The ✕ stopped this plan partway through. It neither finished
          // nor failed, so drop it from the attempted tally (the toast
          // would otherwise read it as an error) and abandon the rest.
          attempted -= 1
          progress?.discardCurrentPlan()
          break planLoop
        case .failed:
          progress?.discardCurrentPlan()
        }
      }
      let finalMovePairs = movePairs
      let finalSucceeded = succeeded
      let finalAttempted = attempted
      await MainActor.run { [weak self, weak sourcePane] in
        guard let self else { return }
        // Only `.move` successes are registered — cross-volume copies and
        // explicit copy / alias leave the source on disk, so ⌘⌫ is the
        // recovery path (matching system Finder).
        if !finalMovePairs.isEmpty {
          FinderUndoCenter.registerMove(
            pairs: finalMovePairs, sourcePane: sourcePane, in: self)
        }
        // A live drop posts no success toast (matching Finder); this is
        // the only feedback for a partial / full failure. `attempted`
        // excludes Stop-skipped and cancel-skipped plans so neither reads
        // as an error.
        self.reportOperationFailure(
          succeeded: finalSucceeded, total: finalAttempted, verbPhrase: verbPhrase)
      }
    }

    FinderOperationTracker.shared.register(
      .init(
        id: opID,
        label: Self.dropProgressLabel(for: op, count: execPlans.count),
        targetURLs: targets,
        cancel: {
          token.cancel()
          task.cancel()
        },
        progress: progress))
    OperationsProgressPanel.scheduleShowIfNeeded(near: window)
  }

  /// Outcome of one plan's filesystem work, accumulated by `runDropBatch`.
  /// `movePair` is non-nil only for a same-volume move that should be
  /// undo-registered; copies, aliases and the cross-volume fallback leave
  /// the source in place and carry `nil`.
  private enum DropPlanOutcome {
    case succeeded(movePair: (origin: URL, destination: URL)?)
    case cancelled
    case failed
  }

  /// Perform one resolved plan's trash-then-move / copy / alias work off
  /// the main actor. Same-volume moves rename instantly; same-volume copies
  /// clonefile through `FileManager`; only the genuinely slow cross-volume
  /// copies — and the rare cross-volume fallback of a move whose volume was
  /// reclassified between validate and accept — route through the
  /// interruptible `cancellableCopy` so the ✕ can abort them mid-file.
  /// `.cancelled` propagates up so `runDropBatch` stops the whole batch.
  private nonisolated static func executeDropPlan(
    _ plan: DropPlan, op: NSDragOperation, token: CopyCancellationToken,
    fm: FileManager, progress: FinderCopyProgress?
  ) -> DropPlanOutcome {
    if plan.replaceExisting {
      // Send the existing target to Trash so the user can recover it from
      // `~/.Trash` — not undo-registered (⌘Z reverses the move only),
      // matching system Finder's Replace.
      do {
        try fm.trashItem(at: plan.target, resultingItemURL: nil)
      } catch {
        logger.error(
          "Drop replace: trash \(plan.target.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        return .failed
      }
    }

    if op == .link {
      do {
        let bookmark = try plan.source.bookmarkData(
          options: .suitableForBookmarkFile,
          includingResourceValuesForKeys: nil,
          relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: plan.target)
        return .succeeded(movePair: nil)
      } catch {
        logger.error(
          "Drop alias failed \(plan.source.path, privacy: .public) → \(plan.target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        return .failed
      }
    }

    if op == .copy {
      // copyfile clones a same-volume copy when the filesystem allows
      // (instant) and otherwise does a cancellable data copy — unlike
      // FileManager.copyItem, which never clones and can't be interrupted.
      switch cancellableCopy(
        from: plan.source, to: plan.target, token: token, progress: progress)
      {
      case .completed: return .succeeded(movePair: nil)
      case .cancelled: return .cancelled
      case .failed(let error):
        logger.error(
          "Drop copy failed \(plan.source.path, privacy: .public) → \(plan.target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        return .failed
      }
    }

    // Move. A cross-volume drag validates as `.copy` (the `+` badge), so a
    // move is same-volume by construction and renames instantly — unless
    // the source's volume was reclassified between validate and accept,
    // surfacing as `EXDEV`. Complete that rare case as a cancellable
    // cross-volume copy, leaving the source in place and out of the undo
    // stack (the same fallback as before, now interruptible); a cancel
    // there abandons the copy and likewise keeps the source.
    do {
      try fm.moveItem(at: plan.source, to: plan.target)
      return .succeeded(movePair: (plan.source, plan.target))
    } catch let error as NSError where isCrossVolumeError(error) {
      switch cancellableCopy(
        from: plan.source, to: plan.target, token: token, progress: progress)
      {
      case .completed: return .succeeded(movePair: nil)
      case .cancelled: return .cancelled
      case .failed(let copyError):
        logger.error(
          "Cross-volume copy failed \(plan.source.path, privacy: .public) → \(plan.target.path, privacy: .public): \(copyError.localizedDescription, privacy: .public)"
        )
        return .failed
      }
    } catch {
      logger.error(
        "Drop move failed \(plan.source.path, privacy: .public) → \(plan.target.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return .failed
    }
  }

  /// Present-tense progress-panel label for a drop batch ("Moving 5
  /// items"), mirroring `runCopyBatch`'s "Pasting …" phrasing and
  /// contrasting with the past-tense failure verb from `verbPhrase`.
  private static func dropProgressLabel(for op: NSDragOperation, count: Int) -> String {
    let verb: String
    if op == .link {
      verb = "Aliasing"
    } else if op == .copy {
      verb = "Copying"
    } else {
      verb = "Moving"
    }
    let suffix = count == 1 ? "1 item" : "\(count) items"
    return "\(verb) \(suffix)"
  }

  /// Past-tense verb for the per-batch failure toast, matched to the
  /// operation the drop performed.
  private static func verbPhrase(for op: NSDragOperation) -> String {
    if op == .link { return "aliased" }
    if op == .copy { return "copied" }
    return "moved"
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
      // `.on` aimed at a file or package row resolves to the enclosing
      // folder. validateDrop retargets such hovers to a whole-pane
      // `.above` drop, so accept normally never lands here with `.on` on
      // a file; this is a defensive fallback that still drops into the
      // cwd (matching Finder, a no-op when the item already lives here)
      // rather than rejecting.
      return currentURL
    }
    // `.above` (between rows or below the last row), or `.on` with an
    // out-of-range row: drop into the pane's cwd.
    return currentURL
  }

  /// Icon-mode counterpart of `resolveDropDestination`, resolving the
  /// row/operation accept receives back from validateDrop. The collection
  /// view's `.on` aimed at a directory cell drops into that cell; `.before`
  /// (gap drop, including the empty area at the end of the grid) drops
  /// into the pane's cwd. The `.on`-a-file/package branch is a defensive
  /// fallback (still the cwd): validateDrop retargets a file cell to a
  /// `.before` cwd drop, so accept does not normally reach it with `.on`.
  func resolveIconDropDestination(
    proposedItem: Int, dropOperation: NSCollectionView.DropOperation
  ) -> URL? {
    if dropOperation == .on, proposedItem >= 0, proposedItem < items.count {
      let item = items[proposedItem]
      if item.isDirectory && !item.isPackage {
        return item.url
      }
      return currentURL
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
  private nonisolated static func isCrossVolumeError(_ error: NSError) -> Bool {
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
