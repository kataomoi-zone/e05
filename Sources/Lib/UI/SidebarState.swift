import Foundation

/// Three-state machine that governs the sidebar's visibility.
///
/// Persisted as the boolean `SessionState.sidebarPinned` (`.pinnedOpen`
/// ↔ true, the others ↔ false). `.hoverPeek` is intentionally ephemeral
/// — restoring a session never reproduces a transient hover reveal.
public enum SidebarState: Equatable {
  /// Fully hidden. Workspace content uses the full window width; only
  /// the edge hit zone listens for hover. Traffic lights are hidden.
  case hidden
  /// Edge-hover temporary reveal. The sidebar overlays the workspace
  /// content (content stays in place) and the traffic lights fade in.
  /// A cursor exit from both the sidebar and the edge zone schedules
  /// a return to `.hidden` after the hover-out delay.
  case hoverPeek
  /// User-pinned reveal. Workspace content is pushed right by
  /// `sidebarWidth`; traffic lights stay visible.
  case pinnedOpen

  /// Whether the sidebar is visible on-screen. `true` for
  /// `.hoverPeek` and `.pinnedOpen`.
  var isRevealed: Bool { self != .hidden }

  /// Whether the workspace's scroll strip should reserve a leading
  /// inset matching the sidebar's width. Both revealed states reserve
  /// the inset: `.pinnedOpen` for the obvious shifted layout and
  /// `.hoverPeek` for AppKit's dispatch logic. The hoverPeek path
  /// then re-introduces the inset's worth of `bounds.origin.x` (in
  /// `applySidebarLayout`) to cancel the visual shift, leaving the
  /// columns at their pre-peek position visually while the inset
  /// itself keeps cursor / tracking dispatch off the leading
  /// `sidebarWidth` strip.
  var reservesLeadingScrollInset: Bool { self != .hidden }
}
