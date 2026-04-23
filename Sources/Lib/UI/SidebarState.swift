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
  /// inset matching the sidebar's width. Only `.pinnedOpen` reserves
  /// — `.hoverPeek` overlays without shifting the columns. The name
  /// is deliberate: earlier revisions pushed the whole workspace
  /// root right and "pushesContent" reflected that, but the current
  /// implementation only inflates `scrollView.contentInsets.left`,
  /// which keeps the root spanning the full window so the sidebar
  /// glass has a blur source behind it.
  var reservesLeadingScrollInset: Bool { self == .pinnedOpen }
}
