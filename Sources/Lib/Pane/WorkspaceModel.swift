import AppKit

/// A group of columns (one horizontal layout). The app owns multiple workspaces
/// for niri / ribari style vertical navigation — switching workspaces replaces
/// the visible column set wholesale.
@MainActor
public final class WorkspaceModel {
    public let id = ULID()

    /// 1-based index into the fixed accent color palette. Assigned on creation
    /// and preserved across deletions so color ↔ workspace mapping stays stable.
    public var accentColorIndex: Int

    public var columns: [ColumnModel] = []
    public var focusedColumnIndex: Int = 0

    /// Last-known horizontal scroll offset. Restored on switch so switching
    /// back lands the user where they were, not at the focused column.
    public var scrollX: CGFloat = 0

    public init(accentColorIndex: Int) {
        self.accentColorIndex = accentColorIndex
    }
}
