import AppKit

/// Process-wide registry of in-flight finder-pane batch operations
/// (Compress, Duplicate, Paste, …). Lives behind a singleton so the
/// progress panel and any pane-side greyed-placeholder rendering can
/// observe a single source of truth without each finder-pane
/// instance bookkeeping its own list.
///
/// Posting `didChangeNotification` is the only update surface — the
/// progress panel subscribes and re-renders, and a future greyed-row
/// pass on `FinderPaneView` will subscribe to inject synthetic
/// `FileItem`s for ops whose targets fall inside the current cwd.
///
/// Operations live entirely on the main actor: registration and
/// unregistration happen from MainActor call sites, and the cancel
/// closure (when present) is invoked from the panel's button on
/// MainActor too. Off-main work (the detached `Task.run` for a zip
/// process or a copy loop) hops back to MainActor before touching
/// the tracker.
@MainActor
public final class FinderOperationTracker {
  public static let shared = FinderOperationTracker()

  /// Posted with `object: shared` whenever the operation list
  /// changes (register / unregister). Subscribers should consult
  /// `operations` rather than reading the userInfo, so an update
  /// burst always reflects the current full state.
  public static let didChangeNotification = Notification.Name(
    "e05.finderOperation.didChange")

  /// Identifier for a single batch op; opaque UUID wrapper so
  /// register / unregister callers can pass the value back without
  /// reaching into the implementation.
  public struct OperationID: Hashable, Sendable {
    public let raw: UUID
    public init() { self.raw = UUID() }
  }

  /// One in-flight batch op. `targetURLs` is plural so a single
  /// Paste / Duplicate that produces N entries registers as one op
  /// (one progress row, one cancel) while still letting the future
  /// greyed-row pass enumerate every per-file target. `cancel: nil`
  /// means the op has no abort path — the panel hides the ✕ button
  /// in that case (Make Alias is fast enough not to register at all,
  /// but the option is there for future ops where cancel isn't
  /// straightforward).
  public struct Operation {
    public let id: OperationID
    public let label: String
    public let targetURLs: [URL]
    public let cancel: (() -> Void)?

    public init(
      id: OperationID, label: String, targetURLs: [URL],
      cancel: (() -> Void)?
    ) {
      self.id = id
      self.label = label
      self.targetURLs = targetURLs
      self.cancel = cancel
    }
  }

  private var byID: [OperationID: Operation] = [:]
  /// Insertion order so the panel renders the rows in the order ops
  /// started, not the dictionary's hash order. Removal is O(N) on
  /// the array, but N is the count of concurrently-running batch
  /// ops — typically 1, occasionally a handful.
  private var order: [OperationID] = []

  private init() {}

  public var operations: [Operation] {
    order.compactMap { byID[$0] }
  }

  /// Targets for in-flight ops whose parent directory equals `dir`.
  /// Used by `FinderPaneView` to inject synthetic placeholder rows
  /// for archives/copies/aliases not yet on disk so the user sees a
  /// greyed row + spinner the moment the op starts, even if the
  /// pane navigates away and back during the op. Returns a `Set` to
  /// dedupe across overlapping ops with the same target (rare;
  /// happens e.g. when two Compresses race for the same archive
  /// name and only one wins the collision-resolved slot). The
  /// dictionary's value sequence is enough — the panel uses `order`
  /// to render rows in start order, but a `Set` of targets has no
  /// useful ordering anyway.
  public func targetURLs(in dir: URL) -> Set<URL> {
    var result: Set<URL> = []
    for op in byID.values {
      for target in op.targetURLs where target.deletingLastPathComponent() == dir {
        result.insert(target)
      }
    }
    return result
  }

  public func register(_ op: Operation) {
    byID[op.id] = op
    if !order.contains(op.id) {
      order.append(op.id)
    }
    post()
  }

  public func unregister(_ id: OperationID) {
    byID.removeValue(forKey: id)
    order.removeAll { $0 == id }
    post()
  }

  /// Invoke the cancel closure for `id` if one was provided. The op
  /// itself is responsible for reaching `unregister` once its
  /// detached work observes the cancellation; calling `cancel` here
  /// alone doesn't drop the entry from the tracker.
  public func cancel(_ id: OperationID) {
    byID[id]?.cancel?()
  }

  private func post() {
    NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
  }
}
