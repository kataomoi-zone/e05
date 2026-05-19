import SwiftUI

/// Appearance settings tab. Routed from ``SettingsTab/appearance``
/// in the Settings sidebar; renders the workspace accent palette
/// and surface corner radius pickers once they ship.
@MainActor
struct AppearanceSettingsView: View {
  var body: some View {
    Form {
      Section {
        Text("Accent palette and surface corner radius will appear here.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}
