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

    /// Whether workspace content should be pushed right to accommodate
    /// the sidebar. Only `.pinnedOpen` pushes — `.hoverPeek` overlays.
    var pushesContent: Bool { self == .pinnedOpen }
}
