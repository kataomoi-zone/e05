import AppKit
import WebKit

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
  /// Stable identity across reloads — also persisted through
  /// `SessionState.WorkspaceState.id` so the sidebar's
  /// `collapsedIds` set survives a save/restore round-trip.
  public let id: ULID

  /// User-assigned name, or `nil` for an unnamed workspace that falls
  /// back to the positional "Workspace N" label. Edited inline in the
  /// sidebar worklane and persisted through `SessionState.WorkspaceState.name`.
  /// Empty / whitespace-only input is normalised back to `nil` so the
  /// fallback re-engages instead of showing a blank row.
  public var name: String?

  public var columns: [ColumnModel] = []
  public var focusedColumnIndex: Int = 0

  /// Last-known horizontal scroll offset. Restored on switch so switching
  /// back lands the user where they were, not at the focused column.
  public var scrollX: CGFloat = 0

  /// Marks this workspace as private — disables history recording,
  /// closed-pane undo, and session persistence; uses an ephemeral
  /// `WKWebsiteDataStore` so cookies, local storage, and cache live
  /// only in memory and disappear when the workspace is closed.
  /// Visually distinguished by a dotted focus border on its panes
  /// and sidebar rows. Aligns with how Safari / Firefox / Brave label
  /// the same feature ("Private Window"), avoiding Chrome's
  /// "Incognito" branding.
  public let isPrivate: Bool

  /// Lazy ephemeral data store for browser panes in this workspace.
  /// Created on first access and reused so cookies / local storage
  /// flow between panes inside the same private workspace, matching
  /// how a Safari Private Window behaves across its tabs. Nil for
  /// non-private workspaces — those use the shared default store
  /// (passed implicitly by `WKWebViewConfiguration.websiteDataStore`).
  public lazy var dataStore: WKWebsiteDataStore? = {
    isPrivate ? WKWebsiteDataStore.nonPersistent() : nil
  }()

  public init(isPrivate: Bool = false, id: ULID = ULID()) {
    self.id = id
    self.isPrivate = isPrivate
  }

  /// User-facing label: the custom `name` when set (trimmed,
  /// non-empty), else the positional "Workspace N" fallback. The
  /// index is passed in because numbering is positional — the model
  /// doesn't know its own slot in the container's `workspaces` array
  /// (see the type doc on why accent / number live outside the model).
  public func displayName(at index: Int) -> String {
    if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    {
      return trimmed
    }
    return "Workspace \(index + 1)"
  }
}
