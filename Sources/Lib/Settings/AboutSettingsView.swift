import AppKit
import SwiftUI

/// "About" tab content. App info / Backup / Reset sections land in
/// follow-up commits — this scaffold + App info commit only renders
/// the app identity row and a link to the Acknowledgements sheet.
@MainActor
struct AboutSettingsView: View {
  @State private var showingAcknowledgements = false

  var body: some View {
    Form {
      Section {
        appInfoRow
      }

      Section("Backup") {
        HStack {
          Text("Preferences")
          Spacer()
          Button("Export…") { exportPreferences() }
          Button("Import…") { importPreferences() }
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showingAcknowledgements) {
      AcknowledgementsView()
    }
  }

  // MARK: - Backup

  private func exportPreferences() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "e05-preferences.json"
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.json]
    guard let parent = SettingsWindowController.shared.window else { return }
    panel.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        guard response == .OK, let url = panel.url else { return }
        do {
          try PreferencesStore.shared.exportTo(url)
        } catch {
          presentError(
            title: "Couldn't export preferences",
            message: error.localizedDescription)
        }
      }
    }
  }

  private func importPreferences() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json]
    panel.message = "Choose a preferences file to import"
    panel.prompt = "Import"
    guard let parent = SettingsWindowController.shared.window else { return }
    panel.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        guard response == .OK, let url = panel.url else { return }
        do {
          try PreferencesStore.shared.importFrom(url)
        } catch {
          presentError(
            title: "Couldn't import preferences",
            message: error.localizedDescription)
        }
      }
    }
  }

  /// Sheet-attached error alert. The Settings panel is the parent so
  /// the modal hold lands on it and Cancel returns focus to Settings
  /// — same pattern as the directory picker in General.
  private func presentError(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    guard let parent = SettingsWindowController.shared.window else {
      alert.runModal()
      return
    }
    alert.beginSheetModal(for: parent) { _ in }
  }

  // MARK: - App info

  private var appInfoRow: some View {
    HStack(alignment: .center, spacing: 16) {
      Image(nsImage: NSApp.applicationIconImage ?? NSImage())
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(width: 64, height: 64)

      VStack(alignment: .leading, spacing: 4) {
        Text(Self.appName)
          .font(.title2)
          .fontWeight(.semibold)
        Text(Self.versionLabel)
          .foregroundStyle(.secondary)
          .font(.subheadline)
        Button("Acknowledgements…") {
          showingAcknowledgements = true
        }
        .buttonStyle(.link)
        .padding(.top, 2)
      }

      Spacer()
    }
    .padding(.vertical, 8)
  }

  /// Fallback chain: `CFBundleDisplayName` (the user-facing override
  /// AppKit reads when both are present, currently rendered as
  /// "e05[DEV]" in the dev bundle) → `CFBundleName` → the literal
  /// "e05" for unit-test hosts that ship without an Info.plist.
  private static var appName: String {
    let info = Bundle.main.infoDictionary
    if let display = info?["CFBundleDisplayName"] as? String, !display.isEmpty {
      return display
    }
    if let name = info?["CFBundleName"] as? String, !name.isEmpty {
      return name
    }
    return "e05"
  }

  /// `"Version <CFBundleShortVersionString> (build <CFBundleVersion>)"`.
  /// Default values surface as "Version 0.0.0 (build 0)" so a
  /// missing Info.plist still renders cleanly during test runs.
  private static var versionLabel: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    let build = info?["CFBundleVersion"] as? String ?? "0"
    return "Version \(version) (build \(build))"
  }
}
