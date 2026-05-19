import SwiftUI

/// Top-level Settings view. The sidebar selects which tab renders in
/// the detail pane; future tabs (Sites / Appearance / Shortcuts /
/// Content Blocker / Terminal) land as additional ``SettingsTab``
/// cases without restructuring the container.
@MainActor
struct SettingsRootView: View {
  @State private var selected: SettingsTab = .general
  /// Pin both columns so SwiftUI does not inject the sidebar toggle
  /// button. NSPanel hosting misplaces that button (NSToolbar
  /// fallback rules differ from NSWindow), and Settings UIs in the
  /// platform (System Settings, Safari, Chrome, Brave) all keep the
  /// sidebar static anyway — collapsing it would only hide the tab
  /// switcher.
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(SettingsTab.allCases, selection: $selected) { tab in
        Label(tab.title, systemImage: tab.symbol)
          .tag(tab)
      }
      .navigationSplitViewColumnWidth(180)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      switch selected {
      case .general:
        GeneralSettingsView()
      case .sites:
        SitesSettingsView()
      case .about:
        AboutSettingsView()
      }
    }
    .frame(minWidth: 720, minHeight: 480)
  }
}

/// `allCases` order drives the sidebar row order. About sits at the
/// bottom by convention so the most-edited tabs (General first,
/// Sites next, future Appearance / Shortcuts above About) stay near
/// the top.
private enum SettingsTab: CaseIterable, Hashable, Identifiable {
  case general
  case sites
  case about

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .sites: "Sites"
    case .about: "About"
    }
  }

  /// SF Symbol for the sidebar row. Picked from system symbols so a
  /// future light-theme switch picks up the appearance automatically.
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .sites: "globe"
    case .about: "info.circle"
    }
  }
}
