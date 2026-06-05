import SwiftUI

/// Top-level Settings view. The sidebar selects which tab renders in
/// the detail pane; a ``SettingsSearchField`` at its top filters the
/// list into cross-tab ``SettingsSearchIndex`` results. New tabs land
/// as additional ``SettingsTab`` cases without restructuring the
/// container.
///
/// Built on a plain `HStack` + `Divider` rather than
/// `NavigationSplitView` because the platform split view still
/// exposes its inter-column divider as a drag handle even when the
/// column width is pinned via `navigationSplitViewColumnWidth(min:
/// ideal: max:)`. A vertical `Divider` inside `HStack` is purely
/// decorative, which gives the same Apple System Settings look
/// without a draggable affordance.
///
/// The sidebar is hand-built from `VStack + Button` (matching the
/// Sites / Content Blocker / Shortcuts sub-sidebars) rather than
/// `List(.sidebar)` because the native sidebar list forces single-
/// line rows (breaking the wrap fallback for long labels such as
/// "Content Blocker") and paints itself with a liquid-glass
/// material that the inner sub-sidebars do not, leaving the
/// surfaces visually inconsistent.
@MainActor
struct SettingsRootView: View {
  @State private var selected: SettingsTab = .general
  /// Cross-tab search query. While non-empty the sidebar swaps its
  /// tab list for ``SettingsSearchIndex`` results; clearing it (or
  /// selecting a result) restores the tab list.
  @State private var searchText: String = ""

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      detail
    }
    .frame(minWidth: 720, minHeight: 480)
  }

  private var trimmedQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      SettingsSearchField(text: $searchText, placeholder: "Search")
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)

      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          if trimmedQuery.isEmpty {
            ForEach(SettingsTab.allCases) { tab in
              sidebarRow(tab)
            }
          } else {
            searchResults
          }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
      }
    }
    .frame(width: 180)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private var searchResults: some View {
    let results = SettingsSearchIndex.search(searchText)
    if results.isEmpty {
      Text("No Results")
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ForEach(results) { entry in
        searchResultRow(entry)
      }
    }
  }

  private func searchResultRow(_ entry: SettingsSearchEntry) -> some View {
    Button {
      // Jump to the owning tab and drop back to the tab list. v1
      // navigates at tab granularity; section scroll/highlight is a
      // deferred follow-up.
      selected = entry.tab
      searchText = ""
    } label: {
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.title)
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(entry.tab.title)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("\(entry.title), \(entry.tab.title)"))
  }

  private func sidebarRow(_ tab: SettingsTab) -> some View {
    Button {
      selected = tab
    } label: {
      HStack(spacing: 8) {
        Image(systemName: tab.symbol).frame(width: 16)
        Text(tab.title)
          .lineLimit(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        tab == selected ? Color.primary.opacity(0.12) : .clear
      )
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(tab.title))
    .accessibilityAddTraits(tab == selected ? .isSelected : [])
  }

  @ViewBuilder
  private var detail: some View {
    switch selected {
    case .general:
      GeneralSettingsView()
    case .terminal:
      TerminalSettingsView()
    case .sites:
      SitesSettingsView()
    case .appearance:
      AppearanceSettingsView()
    case .shortcuts:
      ShortcutsSettingsView()
    case .contentBlocker:
      ContentBlockerSettingsView()
    case .about:
      AboutSettingsView()
    }
  }
}
