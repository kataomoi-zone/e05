import Foundation

/// Three-state machine that governs the URL bar's visibility on a
/// single pane.
///
/// Each `PaneModel` owns its own state — unlike the sidebar (one
/// state for the whole window), URL bar visibility is per-pane so a
/// background pane's bar doesn't slide in just because the user is
/// hovering the focused pane's top edge. `.hovering` is intentionally
/// ephemeral — restoring a session never reproduces a transient
/// hover reveal. `.pinned` is also ephemeral in the current contract:
/// pinned state is dropped at app exit and panes always start in
/// `.hidden` after launch. Persisting the pin state across launches
/// is on the customisation backlog.
public enum URLBarHoverState: Equatable, Sendable {
  /// Fully hidden. The pane content uses its full height; only the
  /// top edge hit zone listens for hover.
  case hidden
  /// Edge-hover temporary reveal. The URL bar slides over the pane
  /// content (or pushes it down — exact layout TBD during step 2)
  /// while the cursor is in the bar or the hit zone, returning to
  /// `.hidden` after the hover-out delay.
  case hovering
  /// User-pinned reveal via ⌘⇧L. The bar stays visible regardless of
  /// cursor position; the hover state machine is short-circuited
  /// while pinned.
  case pinned

  /// Whether the bar should be visible on-screen.
  public var isRevealed: Bool { self != .hidden }

  /// Whether the bar's visibility is locked open by the user. The
  /// hover state machine bypasses scheduling when this is true so a
  /// cursor exit doesn't dismiss the bar.
  public var isPinned: Bool { self == .pinned }
}
