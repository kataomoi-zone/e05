import SwiftUI

/// Open-source dependency credits. Linked from the About tab's app
/// info row through a sheet so the user can scan the list without
/// losing their place in the rest of Settings.
@MainActor
struct AcknowledgementsView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL

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

      List(Acknowledgements.all) { credit in
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .firstTextBaseline) {
            Text(credit.name)
              .font(.headline)
            Spacer()
            Text(credit.license)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          Text(credit.description)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Button("Project page") {
            openURL(credit.url)
          }
          .buttonStyle(.link)
          .font(.subheadline)
          .help(credit.url.absoluteString)
          DisclosureGroup("View license") {
            ScrollView {
              Text(credit.licenseBody)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 240)
          }
          .font(.subheadline)
        }
        .padding(.vertical, 4)
      }
    }
    .frame(minWidth: 480, minHeight: 360)
  }
}
