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
  /// string ends the session and calls back into `endFind()`.
  func performFind(_ needle: String, forward: Bool)

  /// End the current find session and clear any transient state.
  func endFind()
}
