import AppKit
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "FinderUndo")

/// App-global `NSUndoManager` for finder-pane filesystem operations.
///
/// e05 runs all finder panes inside a single window (the 1-window
/// invariant) and Finder's own Undo/Redo is window-scoped, so a
/// single shared stack maps cleanly: rename a file in one pane,
/// trash another in a sibling pane, then walk both back with two
/// presses of ⌘Z. AppKit dispatches `undo:` / `redo:` through the
/// responder chain and lands on `FinderPaneView.undoManager`,
/// which returns this same manager regardless of which pane is
/// first responder.
///
/// Registrations push onto the manager's redo stack automatically
/// when the registered closure runs during an undo (and vice
/// versa) — `NSUndoManager.isUndoing` / `isRedoing` flips the
/// internal stack, so calling `registerUndo` from inside an undo
/// closure stores the inverse on the redo stack with no extra
/// bookkeeping. Each helper here registers its inverse the same
/// way, so the same call site supports both directions.
///
/// Each helper sets its own `setActionName` immediately after the
/// registration; the name is per-entry, so successive registrations
/// don't clobber each other. If we ever introduce explicit
/// `beginUndoGrouping` / `endUndoGrouping` blocks, revisit this —
/// `setActionName` then applies to the whole group, not a single
/// registration.
/// Action-name constants for the undo / redo manager. These propagate
/// into the menu-bar Edit > Undo X / Redo X title via
/// `manager.setActionName`, and a few of them are referenced from the
/// pane's call sites (`runCopyBatch`'s `label`, `makeAliasForSelection`).
/// Centralising them here keeps the strings in lockstep — bare string
/// literals at the call site would drift the moment one user-visible
/// label is reworded.
public enum FinderUndoActionName {
  public static let rename = "Rename"
  public static let moveToTrash = "Move to Trash"
  public static let newFolder = "New Folder"
  public static let duplicate = "Duplicate"
  public static let paste = "Paste"
  public static let newFolderWithSelection = "New Folder with Selection"
  public static let move = "Move"
}

@MainActor
public enum FinderUndoCenter {
  public static let manager: UndoManager = {
    let m = UndoManager()
    // Cap depth so a long-running session doesn't grow unbounded.
    // 200 keeps a few hours of typical activity in scope.
    m.levelsOfUndo = 200
    return m
  }()

  /// Side channel for partial-failure feedback that needs to reach
  /// `+Clipboard.swift`'s `postUndoToast` after the manager closure
  /// has already returned. `reportPartialBatchFailure` writes here
  /// from inside an undo/redo closure; the `undo:` / `redo:` action
  /// handlers clear it before invoking the manager and read it
  /// after so the success toast can be suppressed (full failure)
  /// or rephrased with succeeded/total counts. `nil` when the last
  /// action was either fully successful or non-batch (rename /
  /// single new folder). `internal(set)` because the only writer is
  /// `reportPartialBatchFailure` in this same enum; readers (the
  /// post-undo handler) need public access. Reads are scoped to the
  /// immediate post-`manager.undo()` window — the handler nils the
  /// flag again on exit so a stale value never bleeds into the next
  /// undo/redo cycle.
  public internal(set) static var lastBatchPartial: (succeeded: Int, total: Int)?

  // MARK: - Rename

  /// Register a `from → to` rename so ⌘Z reverses it via
  /// `moveItem(to → from)`. The pane is captured weakly via the
  /// `withTarget:` closure parameter — `NSUndoManager` keeps a
  /// weak reference to the target so a torn-down pane doesn't
  /// keep the manager alive.
  public static func registerRename(
    from oldURL: URL,
    to newURL: URL,
    in pane: FinderPaneView
  ) {
    manager.registerUndo(withTarget: pane) { target in
      // `assumeIsolated` is a Swift 6 strict-concurrency requirement,
      // not a thread hop: `undo()` is invoked synchronously from
      // `FinderPaneView.undo(_:)` on main, so the closure already
      // runs on the main actor. The annotation is what lets us touch
      // the MainActor-isolated pane without an `await`.
      MainActor.assumeIsolated {
        do {
          try FileManager.default.moveItem(at: newURL, to: oldURL)
          // Register the inverse so the redo stack walks back the
          // other direction. `NSUndoManager` routes this onto the
          // redo stack while `isUndoing == true`.
          registerRename(from: newURL, to: oldURL, in: target)
          target.reloadItemsAndSelect(at: [oldURL])
        } catch {
          logger.error(
            "Undo rename \(newURL.path, privacy: .public) → \(oldURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    manager.setActionName(FinderUndoActionName.rename)
  }

  // MARK: - Partial-failure feedback

  /// Surface an error toast describing a partial-failure batch
  /// undo/redo: silent on full success, factual sentence on a
  /// partial recovery. The verb phrase reflects the closure's
  /// direction so each call site reads naturally:
  /// - `"restored"` for Trash → origin (entries returning from an
  ///   external Trash "sink" — the implication is recovery)
  /// - `"moved to Trash"` for origin → Trash
  /// - `"moved back"` for drag-undo (within-app reversal of a move,
  ///   no Trash semantics so factual "moved back" beats "restored")
  /// - `"moved"` for drag-redo
  /// - `"moved into folder"` for the New-Folder-with-Selection redo
  ///
  /// The success toast (`<action> undone` / `<action> redone`)
  /// still posts from `+Clipboard.swift`'s `postUndoToast` after
  /// the manager closure returns, so the user sees both: the
  /// action on top, the partial-failure caveat just below.
  /// `total == 0` is unreachable: every call site guards against
  /// empty pair lists before invoking the closure that ends up
  /// here.
  static func reportPartialBatchFailure(
    target: FinderPaneView,
    succeeded: Int,
    total: Int,
    verbPhrase: String
  ) {
    guard succeeded < total else { return }
    Self.lastBatchPartial = (succeeded: succeeded, total: total)
    let failed = total - succeeded
    let itemPhrase = total == 1 ? "1 item" : "\(failed) of \(total) items"
    let message = "\(itemPhrase) couldn't be \(verbPhrase)"
    guard let container = target.window?.contentViewController as? PaneContainerViewController else {
      // Diagnostic: the per-item moveItem already logged its own
      // failure, but the user never saw the toast. Without this
      // line a teardown / detached-window state surfaces as
      // "the partial failure is invisible" with no clue why.
      logger.error("Partial-failure toast dropped: container unresolved (\(message, privacy: .public))")
      return
    }
    container.showToast(message, style: .error)
  }

  // MARK: - Move to Trash

  /// Pair every successfully trashed entry with the URL the system
  /// actually wrote it under (collision-resolved by `trashItem`'s
  /// `resultingItemURL`) so the undo can restore each one to its
  /// original path. Per-item failures from `trashSelection` are
  /// excluded by the caller; this function only sees pairs that
  /// already round-tripped to the Trash. The whole batch becomes a
  /// single undo entry — one ⌘Z brings the entire selection back
  /// at once.
  ///
  /// Naming note: like the other helpers here, this both registers
  /// the inverse with `NSUndoManager` and, when the manager later
  /// invokes the closure, performs the inverse `moveItem`. The
  /// "register*" prefix reflects the call-site verb, not the
  /// closure's behaviour.
  public static func registerTrash(
    pairs: [(origin: URL, trashed: URL)],
    in pane: FinderPaneView
  ) {
    guard !pairs.isEmpty else { return }
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        var restored: [(origin: URL, trashed: URL)] = []
        for pair in pairs {
          do {
            try FileManager.default.moveItem(at: pair.trashed, to: pair.origin)
            restored.append(pair)
          } catch {
            logger.error(
              "Undo trash \(pair.trashed.path, privacy: .public) → \(pair.origin.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        // Redo re-trashes whatever we managed to restore. If a
        // partial recovery happens (some items couldn't move back),
        // only the recovered subset is eligible for re-trashing —
        // matches what the user can see on disk.
        if !restored.isEmpty {
          registerTrashRedo(originals: restored.map { $0.origin }, in: target)
        }
        target.reloadItemsAndSelect(at: restored.map { $0.origin })
        reportPartialBatchFailure(
          target: target, succeeded: restored.count, total: pairs.count,
          verbPhrase: "restored")
      }
    }
    manager.setActionName(FinderUndoActionName.moveToTrash)
  }

  /// Re-trash a previously undone batch, then re-register the undo
  /// path so a subsequent ⌘Z works again. Each `trashItem` call
  /// fills in `resultingItemURL` with the actual on-disk URL —
  /// trash collisions can append a timestamp / counter suffix that
  /// the second visit may not match the first.
  private static func registerTrashRedo(originals: [URL], in pane: FinderPaneView) {
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        var pairs: [(origin: URL, trashed: URL)] = []
        for origin in originals {
          var resulting: NSURL?
          do {
            try FileManager.default.trashItem(at: origin, resultingItemURL: &resulting)
            if let resulting = resulting as URL? {
              pairs.append((origin, resulting))
            }
          } catch {
            logger.error(
              "Redo trash \(origin.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        if !pairs.isEmpty {
          registerTrash(pairs: pairs, in: target)
        }
        reportPartialBatchFailure(
          target: target, succeeded: pairs.count, total: originals.count,
          verbPhrase: "moved to Trash")
      }
    }
    manager.setActionName(FinderUndoActionName.moveToTrash)
  }

  // MARK: - Created entries (Duplicate / Paste / Make Alias)

  /// Register a batch of newly-created entries so ⌘Z sends them to
  /// the Trash and ⌘⇧Z brings them back to the original paths. Used
  /// by Duplicate, Paste, and Make Alias — all three produce new
  /// rows under the cwd and want the undo to delete those rows
  /// safely (Trash, not unlink, so a misclick stays recoverable).
  ///
  /// `actionName` propagates into the menu-bar Edit > Undo X /
  /// Redo X title via `setActionName`. `runCopyBatch`'s `label`
  /// argument feeds straight into this for Duplicate / Paste;
  /// Make Alias uses the literal "Make Alias".
  public static func registerCreated(
    at urls: [URL],
    actionName: String,
    in pane: FinderPaneView
  ) {
    guard !urls.isEmpty else { return }
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        var pairs: [(origin: URL, trashed: URL)] = []
        for origin in urls {
          var resulting: NSURL?
          do {
            try FileManager.default.trashItem(at: origin, resultingItemURL: &resulting)
            if let resulting = resulting as URL? {
              pairs.append((origin, resulting))
            }
          } catch {
            logger.error(
              "Undo \(actionName, privacy: .public) \(origin.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        if !pairs.isEmpty {
          registerCreatedRedo(pairs: pairs, actionName: actionName, in: target)
        }
        // The originals are gone (they're in Trash now), so a
        // last-component match against `items` would miss anyway.
        // Pass an empty target list so the table just reloads
        // without trying to highlight a row that doesn't exist.
        target.reloadItemsAndSelect(at: [])
        reportPartialBatchFailure(
          target: target, succeeded: pairs.count, total: urls.count,
          verbPhrase: "moved to Trash")
      }
    }
    manager.setActionName(actionName)
  }

  /// Redo path: move every (origin, trashed) pair back to its
  /// original cwd path, then re-register the undo so the cycle
  /// continues. The closure body shares its trashed → origin
  /// move with `registerTrash`'s undo body — the difference is
  /// only that this lives on the redo stack instead of the undo
  /// stack.
  private static func registerCreatedRedo(
    pairs: [(origin: URL, trashed: URL)],
    actionName: String,
    in pane: FinderPaneView
  ) {
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        var restored: [URL] = []
        for pair in pairs {
          do {
            try FileManager.default.moveItem(at: pair.trashed, to: pair.origin)
            restored.append(pair.origin)
          } catch {
            logger.error(
              "Redo \(actionName, privacy: .public) \(pair.origin.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        if !restored.isEmpty {
          registerCreated(at: restored, actionName: actionName, in: target)
        }
        target.reloadItemsAndSelect(at: restored)
        reportPartialBatchFailure(
          target: target, succeeded: restored.count, total: pairs.count,
          verbPhrase: "restored")
      }
    }
    manager.setActionName(actionName)
  }

  // MARK: - Move (drag-and-drop)

  /// Register a batch of `(origin → destination)` moves so ⌘Z reverses
  /// each `moveItem` and ⌘⇧Z replays it. Used by drag-and-drop drops
  /// that resolve to `.move` (same-volume drags). Cross-volume
  /// fallbacks that ended up as `copyItem` are intentionally not
  /// registered here — system Finder leaves cross-volume copies out of
  /// its undo stack since the source is still on disk and ⌘⌫ removes
  /// the copy.
  ///
  /// The pane parameter is the drop *destination*; `sourcePane` is
  /// the pane the drag originated from, when one is identifiable
  /// (in-app drag from a finder pane) — `nil` for drags that came
  /// from outside the app (system Finder, an editor, etc.). On undo,
  /// entries are restored to their original parent directory. The
  /// drag-source pane's directory monitor catches the restoration
  /// and debounces a reload, but row selection / scroll position
  /// don't follow from a monitor reload — `reloadItemsAndSelect`
  /// against the restored origins makes the source pane immediately
  /// jump to the freshly-back rows the same way the destination
  /// pane jumped to the destinations on the forward path.
  ///
  /// When `sourcePane` is the same instance as `pane` (drag inside
  /// one pane onto a visible subfolder row), the same-pane branch
  /// applies the source select directly to `target` — calling both
  /// `target.reloadItemsAndSelect(at: [])` and
  /// `sourcePane.reloadItemsAndSelect(at: origins)` against the same
  /// pane would race the second call's selection over the first's
  /// empty select.
  public static func registerMove(
    pairs: [(origin: URL, destination: URL)],
    sourcePane: FinderPaneView?,
    in pane: FinderPaneView
  ) {
    guard !pairs.isEmpty else { return }
    manager.registerUndo(withTarget: pane) { [weak sourcePane] target in
      MainActor.assumeIsolated {
        var restored: [(origin: URL, destination: URL)] = []
        for pair in pairs {
          do {
            try FileManager.default.moveItem(at: pair.destination, to: pair.origin)
            restored.append(pair)
          } catch {
            logger.error(
              "Undo move \(pair.destination.path, privacy: .public) → \(pair.origin.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        if !restored.isEmpty {
          registerMoveRedo(pairs: restored, sourcePane: sourcePane, in: target)
        }
        let origins = restored.map { $0.origin }
        if let sourcePane, sourcePane === target {
          target.reloadItemsAndSelect(at: origins)
        } else {
          target.reloadItemsAndSelect(at: [])
          // The explicit reload races the source pane's directory
          // monitor: the restoring `moveItem` writes fire a debounced
          // reload (~100ms later) that calls `reloadItems(preservingSelection: true)`
          // and would cancel an in-flight `selectAfterLoad` walk if
          // the source cwd is huge enough to take longer. Typical
          // directories complete inside the debounce window so the
          // selection sticks; pathologically large source cwds may
          // surface as "entries restored, selection lost".
          sourcePane?.reloadItemsAndSelect(at: origins)
        }
        reportPartialBatchFailure(
          target: target, succeeded: restored.count, total: pairs.count,
          verbPhrase: "moved back")
      }
    }
    manager.setActionName(FinderUndoActionName.move)
  }

  private static func registerMoveRedo(
    pairs: [(origin: URL, destination: URL)],
    sourcePane: FinderPaneView?,
    in pane: FinderPaneView
  ) {
    manager.registerUndo(withTarget: pane) { [weak sourcePane] target in
      MainActor.assumeIsolated {
        var moved: [(origin: URL, destination: URL)] = []
        for pair in pairs {
          do {
            try FileManager.default.moveItem(at: pair.origin, to: pair.destination)
            moved.append(pair)
          } catch {
            logger.error(
              "Redo move \(pair.origin.path, privacy: .public) → \(pair.destination.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        if !moved.isEmpty {
          registerMove(pairs: moved, sourcePane: sourcePane, in: target)
        }
        // The destination-side select is the same in both same-pane
        // and cross-pane redo paths (target gained the entries), so
        // the symmetric branching the undo path uses would just
        // duplicate it. Skip the source-side empty reload when the
        // source equals target — calling it would race the empty
        // select over the meaningful destination select on the same
        // pane.
        target.reloadItemsAndSelect(at: moved.map { $0.destination })
        if let sourcePane, sourcePane !== target {
          sourcePane.reloadItemsAndSelect(at: [])
        }
        reportPartialBatchFailure(
          target: target, succeeded: moved.count, total: pairs.count,
          verbPhrase: "moved")
      }
    }
    manager.setActionName(FinderUndoActionName.move)
  }

  // MARK: - New Folder with Selection

  /// Composite undo for "New Folder with Selection": move every
  /// entry back out to its original cwd path, then remove the
  /// (now-empty) folder. The redo replays both halves — recreate
  /// the folder, then move every entry back into it. The pair list
  /// captures the actual `(source, destination)` paths the forward
  /// operation used, so partial-success batches survive: only the
  /// successfully-moved entries get walked back, and only those
  /// re-roundtripped pairs are eligible for the next redo.
  public static func registerNewFolderWithSelection(
    folder: URL,
    moves: [(origin: URL, destination: URL)],
    in pane: FinderPaneView
  ) {
    guard !moves.isEmpty else { return }
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        let fm = FileManager.default
        var restored: [(origin: URL, destination: URL)] = []
        for move in moves {
          do {
            try fm.moveItem(at: move.destination, to: move.origin)
            restored.append(move)
          } catch {
            logger.error(
              "Undo new folder with selection \(move.destination.path, privacy: .public) → \(move.origin.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        // Only remove the folder when every move succeeded. A
        // partial-restore leaves orphaned entries inside, and
        // `removeItem` would nuke them — same protection
        // `registerNewFolder` applies for paste/drop content
        // dropped into the folder after creation.
        if restored.count == moves.count {
          if let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil),
            entries.isEmpty
          {
            do {
              try fm.removeItem(at: folder)
            } catch {
              logger.error(
                "Undo new folder with selection remove \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
              )
            }
          }
        }
        registerNewFolderWithSelectionRedo(
          folder: folder, moves: restored, in: target)
        target.reloadItemsAndSelect(at: restored.map { $0.origin })
        reportPartialBatchFailure(
          target: target, succeeded: restored.count, total: moves.count,
          verbPhrase: "moved back")
      }
    }
    manager.setActionName(FinderUndoActionName.newFolderWithSelection)
  }

  private static func registerNewFolderWithSelectionRedo(
    folder: URL,
    moves: [(origin: URL, destination: URL)],
    in pane: FinderPaneView
  ) {
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        let fm = FileManager.default
        do {
          try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
          logger.error(
            "Redo new folder with selection createDirectory \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
          return
        }
        var moved: [(origin: URL, destination: URL)] = []
        for move in moves {
          do {
            try fm.moveItem(at: move.origin, to: move.destination)
            moved.append(move)
          } catch {
            logger.error(
              "Redo new folder with selection \(move.origin.path, privacy: .public) → \(move.destination.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        if !moved.isEmpty {
          registerNewFolderWithSelection(folder: folder, moves: moved, in: target)
        }
        target.reloadItemsAndSelect(at: [folder])
        reportPartialBatchFailure(
          target: target, succeeded: moved.count, total: moves.count,
          verbPhrase: "moved into folder")
      }
    }
    manager.setActionName(FinderUndoActionName.newFolderWithSelection)
  }

  // MARK: - New Folder

  /// Register a `createDirectory` so ⌘Z removes the folder and ⌘⇧Z
  /// re-creates it.
  ///
  /// Two safeguards on the inverse:
  /// - `cancelRenameIfActive()` first, so a ⌘Z fired within the
  ///   50ms window after `createNewFolder` (between the folder
  ///   appearing and the field editor attaching) doesn't leave
  ///   the field editor pointing at a row whose backing URL is
  ///   about to vanish.
  /// - empty-directory check before `removeItem`. If anything
  ///   landed inside the folder between create and undo (a paste,
  ///   a drag-drop, an external write), `removeItem(at:)` would
  ///   nuke that content too. Bail with a warning instead so the
  ///   user's added files survive — they can ⌘Z further back to
  ///   undo whatever put them there.
  ///
  /// Redo recreates an *empty* folder at the original URL: a
  /// rename done before the undo (separate entry) is unwound first
  /// by the rename undo, so by the time creation undo runs, the
  /// folder name is back to `untitled folder`. Same shape Finder
  /// gives the user.
  public static func registerNewFolder(at url: URL, in pane: FinderPaneView) {
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        target.cancelRenameIfActive()
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil),
          !entries.isEmpty
        {
          logger.warning(
            "Undo new folder skipped — \(url.path, privacy: .public) is no longer empty"
          )
          return
        }
        do {
          try fm.removeItem(at: url)
          registerNewFolderRedo(at: url, in: target)
          // The folder itself is gone; reload without re-selecting.
          target.reloadItemsAndSelect(at: [])
        } catch {
          logger.error(
            "Undo new folder \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    manager.setActionName(FinderUndoActionName.newFolder)
  }

  private static func registerNewFolderRedo(at url: URL, in pane: FinderPaneView) {
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        do {
          try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false)
          registerNewFolder(at: url, in: target)
          target.reloadItemsAndSelect(at: [url])
        } catch {
          logger.error(
            "Redo new folder \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    manager.setActionName(FinderUndoActionName.newFolder)
  }
}
