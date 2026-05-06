import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "FinderUndo")

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
@MainActor
public enum FinderUndoCenter {
  public static let manager: UndoManager = {
    let m = UndoManager()
    // Cap depth so a long-running session doesn't grow unbounded.
    // 200 keeps a few hours of typical activity in scope.
    m.levelsOfUndo = 200
    return m
  }()

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
          target.reloadItemsAndSelect(at: oldURL)
        } catch {
          logger.error(
            "Undo rename \(newURL.path, privacy: .public) → \(oldURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    manager.setActionName("Rename")
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
        if let first = restored.first?.origin {
          target.reloadItemsAndSelect(at: first)
        }
      }
    }
    manager.setActionName("Move to Trash")
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
      }
    }
    manager.setActionName("Move to Trash")
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
          target.reloadItemsAndSelect(at: url.deletingLastPathComponent())
        } catch {
          logger.error(
            "Undo new folder \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    manager.setActionName("New Folder")
  }

  private static func registerNewFolderRedo(at url: URL, in pane: FinderPaneView) {
    manager.registerUndo(withTarget: pane) { target in
      MainActor.assumeIsolated {
        do {
          try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false)
          registerNewFolder(at: url, in: target)
          target.reloadItemsAndSelect(at: url)
        } catch {
          logger.error(
            "Redo new folder \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }
    }
    manager.setActionName("New Folder")
  }
}
