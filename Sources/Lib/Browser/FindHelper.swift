import AppKit

/// Abstraction for incremental find-in-page driven by `FindBarView`.
///
/// Browser panes implement this by forwarding to
/// `WKWebView.find(_:configuration:completionHandler:)`. Terminal panes
/// will implement it by dispatching `search:<needle>` action strings
/// through `ghostty_surface_binding_action`, so the find bar UI stays
/// ignorant of the underlying engine.
@MainActor
public protocol FindHelper: AnyObject {
  /// Search for `needle` and reveal the next match. Passing an empty
  /// string ends the session and calls back into `endFind()`. The
  /// completion reports the current position: `total` is the number
  /// of hits found after filtering, `current` is the 1-based index
  /// of the hit the caller should treat as active (0 when no hit
  /// exists or the engine couldn't resolve a position).
  func performFind(
    _ needle: String,
    forward: Bool,
    completion: @escaping @MainActor ((total: Int, current: Int)) -> Void
  )

  /// End the current find session and clear any transient state.
  func endFind()

  /// Whether `performFind`'s `forward` axis carries meaning. Browser
  /// / terminal find walks next/previous matches and the find bar's
  /// ↑ / ↓ buttons step through them; finder-pane filter narrows
  /// the visible row list with no notion of "next match" — the
  /// result *is* the visible list. The find bar reads this on open
  /// to hide the stepping arrows and switch the position label to
  /// a plain count for non-stepping helpers.
  var supportsStepping: Bool { get }
}

extension FindHelper {
  public var supportsStepping: Bool { true }
}
