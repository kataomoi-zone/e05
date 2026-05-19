import SwiftUI

/// Open-source dependency credits. Linked from the About tab's app
/// info row; the body is intentionally placeholder in this scaffold
/// commit so the link/sheet plumbing lands first, and the actual
/// dependency entries arrive in a follow-up commit.
@MainActor
struct AcknowledgementsView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Acknowledgements")
          .font(.title2)
          .fontWeight(.semibold)
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding()

      Divider()

      List {
        Text("Coming soon")
          .foregroundStyle(.tertiary)
      }
    }
    .frame(minWidth: 480, minHeight: 360)
  }
}
