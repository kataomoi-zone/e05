import AppKit

/// A group of columns (one horizontal layout). The app owns multiple workspaces
/// for niri / ribari style vertical navigation — switching workspaces replaces
/// the visible column set wholesale.
///
/// Accent color is *not* a property of the model: it's determined by the
/// workspace's current position in the container's `workspaces` array, so
/// number ↔ color stays in sync with the displayed "Workspace N" labels
/// even when workspaces are created or closed.
@MainActor
public final class WorkspaceModel {
    public let id = ULID()

    public var columns: [ColumnModel] = []
    public var focusedColumnIndex: Int = 0

    /// Last-known horizontal scroll offset. Restored on switch so switching
    /// back lands the user where they were, not at the focused column.
    public var scrollX: CGFloat = 0

    public init() {}
}
