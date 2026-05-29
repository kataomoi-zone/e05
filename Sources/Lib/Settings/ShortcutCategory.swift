import Foundation

/// Display-side grouping for the Shortcuts settings tab. The
/// registry order in ``PaneContainerViewController/actions()`` is
/// already segmented by `separatorBefore`; this enum widens those
/// segments into seven user-facing buckets so the sub-sidebar stays
/// short and the right-hand list of customisable rows stays
/// scannable.
///
/// Dynamic actions (`workspace_switch_<id>`,
/// `workspace_move_pane_<id>`, `focus_pane_<id>`) are intentionally
/// not categorised — they are runtime-generated and would balloon
/// the list while not being meaningfully customisable across
/// sessions.
public enum ShortcutCategory: String, CaseIterable, Identifiable, Sendable {
  case panes
  case focus
  case findURL
  case browser
  case finder
  case window
  case workspace

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .panes: return "Panes"
    case .focus: return "Focus & Layout"
    case .findURL: return "Find & URL"
    case .browser: return "Browser"
    case .finder: return "Files"
    case .window: return "Window"
    case .workspace: return "Workspaces"
    }
  }

  public var symbol: String {
    switch self {
    case .panes: return "rectangle.split.3x1"
    case .focus: return "arrow.up.and.down.and.arrow.left.and.right"
    case .findURL: return "magnifyingglass"
    case .browser: return "globe"
    case .finder: return "folder"
    case .window: return "macwindow"
    case .workspace: return "square.stack.3d.up"
    }
  }

  /// Resolve the category for a given static action id. Returns
  /// `nil` for runtime-generated ids (`workspace_switch_*` /
  /// `workspace_move_pane_*` / `focus_pane_*`) so the Shortcuts tab
  /// can skip them without a separate predicate.
  public static func category(for actionId: String) -> ShortcutCategory? {
    if let mapped = staticMap[actionId] { return mapped }
    return nil
  }

  /// All static action ids, grouped by category in the display
  /// order the Shortcuts tab uses. The order here also drives the
  /// row order within each detail list.
  public static let staticOrder: [(ShortcutCategory, [String])] = [
    (
      .panes,
      [
        "new_terminal_pane",
        "new_browser_pane",
        "new_finder_pane",
        "split_vertical",
        "undo_close",
        "close_pane",
      ]
    ),
    (
      .focus,
      [
        "focus_left",
        "focus_right",
        "focus_down",
        "focus_up",
        "next_pane",
        "prev_pane",
        "move_column_left",
        "move_column_right",
        "move_pane_down",
        "move_pane_up",
        "cycle_width",
        "toggle_fold",
      ]
    ),
    (
      .findURL,
      [
        "focus_url_bar",
        "toggle_url_bar",
        "pane_find",
        "pane_find_next",
        "pane_find_prev",
      ]
    ),
    (
      .browser,
      [
        "toggle_bookmark",
        "toggle_inspector",
        "browser_reload",
        "browser_hard_reload",
        "browser_back",
        "browser_forward",
        "browser_zoom_in",
        "browser_zoom_out",
        "browser_zoom_reset",
        "browser_suspend",
        "browser_keep_active",
      ]
    ),
    (
      .finder,
      [
        "toggle_hidden_files",
        "finder_view_as_icons",
        "finder_view_as_list",
        "new_folder",
        "move_to_trash",
      ]
    ),
    (
      .window,
      [
        "open_settings",
        "command_palette",
        "toggle_sidebar_pin",
        "open_bookmarks",
        "open_history",
        "open_downloads",
      ]
    ),
    (
      .workspace,
      [
        "workspace_new",
        "workspace_new_private",
        "workspace_close",
        "workspace_next",
        "workspace_prev",
      ]
    ),
  ]

  private static let staticMap: [String: ShortcutCategory] = {
    var dict: [String: ShortcutCategory] = [:]
    for (category, ids) in staticOrder {
      for id in ids { dict[id] = category }
    }
    return dict
  }()
}
