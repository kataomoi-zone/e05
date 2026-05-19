import SwiftUI

/// Sites settings tab — placeholder. The host-keyed master view
/// (Mute / Camera / Microphone / Location / Notifications / Always
/// Active) lands in a follow-up commit. Keeping the scaffold separate
/// lets the routing and sidebar wiring land first so the master view
/// commit can focus on iteration UI without touching tab plumbing.
@MainActor
struct SitesSettingsView: View {
  var body: some View {
    Form {
      Section {
        Text("Per-site preferences will land here.")
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }
}
