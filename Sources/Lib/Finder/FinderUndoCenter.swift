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
}
