import SwiftUI

/// Top-level Settings view. The sidebar selects which tab renders in
/// the detail pane; future tabs (Terminal) land as additional
/// ``SettingsTab`` cases without restructuring the container.
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

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      detail
    }
    .frame(minWidth: 720, minHeight: 480)
  }

  private var sidebar: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(SettingsTab.allCases) { tab in
          sidebarRow(tab)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .frame(width: 180)
    .background(Color(nsColor: .windowBackgroundColor))
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

/// `allCases` order drives the sidebar row order. About sits at the
/// bottom by convention so the most-edited tabs (General first,
/// Sites / Appearance / Shortcuts / Content Blocker above About)
/// stay near the top.
private enum SettingsTab: CaseIterable, Hashable, Identifiable {
  case general
  case sites
  case appearance
  case shortcuts
  case contentBlocker
  case about

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .sites: "Sites"
    case .appearance: "Appearance"
    case .shortcuts: "Shortcuts"
    case .contentBlocker: "Content Blocker"
    case .about: "About"
    }
  }

  /// SF Symbol for the sidebar row. Picked from system symbols so a
  /// future light-theme switch picks up the appearance automatically.
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .sites: "globe"
    case .appearance: "paintbrush.fill"
    case .shortcuts: "keyboard"
    case .contentBlocker: "shield.lefthalf.filled"
    case .about: "info.circle"
    }
  }
}
