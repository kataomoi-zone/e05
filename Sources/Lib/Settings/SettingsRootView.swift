import SwiftUI

/// Top-level Settings view. The sidebar selects which tab renders in
/// the detail pane; future tabs (Sites / Suspend / Extensions / etc.)
/// land as additional ``SettingsTab`` cases without restructuring the
/// container.
@MainActor
struct SettingsRootView: View {
  @State private var selected: SettingsTab = .general

  var body: some View {
    NavigationSplitView {
      List(SettingsTab.allCases, selection: $selected) { tab in
        Label(tab.title, systemImage: tab.symbol)
          .tag(tab)
      }
      .navigationSplitViewColumnWidth(180)
    } detail: {
      switch selected {
      case .general:
        GeneralSettingsView()
      }
    }
    .frame(minWidth: 720, minHeight: 480)
  }
}

private enum SettingsTab: CaseIterable, Hashable, Identifiable {
  case general

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    }
  }

  /// SF Symbol for the sidebar row. Picked from system symbols so a
  /// future light-theme switch picks up the appearance automatically.
  var symbol: String {
    switch self {
    case .general: "gearshape"
    }
  }
}
