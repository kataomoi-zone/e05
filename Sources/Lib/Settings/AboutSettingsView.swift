import SwiftUI

/// "About" tab content. Hosts three sections in follow-up commits:
/// app info (version + build + Acknowledgements link), Backup
/// (Export / Import preferences as JSON), and Reset (per-domain
/// destructive actions with confirmation alerts). The empty body
/// here keeps the tab routable from the sidebar so each section
/// lands as a separate, reviewable change.
@MainActor
struct AboutSettingsView: View {
  var body: some View {
    Form {
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
