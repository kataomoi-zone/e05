import SwiftUI

/// Top-level Settings view. Future tabs (General / Sites / Suspend /
/// Extensions / etc.) land here as ``NavigationSplitView`` sidebar
/// entries; the empty body in this initial commit keeps the window
/// infrastructure landing-able on its own so each tab can ship as a
/// separate, reviewable change.
@MainActor
struct SettingsRootView: View {
  var body: some View {
    NavigationSplitView {
      List {
        Text("General")
          .foregroundStyle(.tertiary)
      }
      .navigationSplitViewColumnWidth(160)
    } detail: {
      Text("Coming soon")
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minWidth: 720, minHeight: 480)
  }
}
