import SwiftUI

/// Terminal tab placeholder. The full editor + validator wiring lands
/// in follow-up commits; this scaffold lets the sidebar route to the
/// new tab without dragging the implementation in alongside the
/// SettingsTab enum change.
@MainActor
struct TerminalSettingsView: View {
  var body: some View {
    Form {
      Text("Terminal settings are coming soon.")
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }
}
