/// Three-state machine that governs the URL bar's visibility on a
/// single pane.
///
/// Each `PaneModel` owns its own state, but visibility actually
/// resolves on two axes: a window-global `urlBarVisible` flag toggled
/// by the menu / palette action, and a per-pane "peek" reveal driven
/// by ⌘L on the focused pane. The global flag pins every pane to
/// `.pinned`; with the flag off, ⌘L promotes only the focused pane
/// to `.peek`, which collapses back to `.hidden` once the URL is
/// finalised or Esc cancels the field. Peek and pinned never coexist
/// on the same pane — peek is a no-op while the global flag is on.
public enum URLBarHoverState: Equatable, Sendable {
  /// Fully hidden. The pane content uses its full height.
  case hidden
  /// Temporary reveal driven by ⌘L on the focused pane while the
  /// global toggle is off. Collapses back to `.hidden` when the
  /// user finalises a URL or dismisses the field with Esc.
  case peek
  /// Reveal driven by the global toggle. All panes share this state
  /// while the toggle is on; turning the toggle off snaps every
  /// pane back to `.hidden`.
  case pinned

  /// Whether the bar should be visible on-screen.
  public var isRevealed: Bool { self != .hidden }

  /// Whether the bar's visibility is locked open by the global flag.
  /// Peek is short-lived and self-collapses; pinned outlives focus
  /// changes within the same global toggle session.
  public var isPinned: Bool { self == .pinned }
}
