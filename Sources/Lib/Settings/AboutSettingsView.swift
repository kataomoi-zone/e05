import AppKit
import SwiftUI

/// "About" tab content: app identity row + Acknowledgements link,
/// Backup (Export / Import preferences), and Reset (per-domain
/// destructive actions, each gated by a confirmation sheet).
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

      Section {
        resetRow(
          label: "Preferences",
          buttonTitle: "Reset to Defaults",
          confirmTitle: "Reset all preferences to defaults?",
          confirmMessage:
            "Homepage, search engine, and download policy revert to their initial values. Site permissions, history, bookmarks, and downloads are not affected."
        ) {
          PreferencesStore.shared.update { $0 = .default }
        }

        resetRow(
          label: "Browsing history",
          buttonTitle: "Clear",
          confirmTitle: "Clear all browsing history?",
          confirmMessage:
            "Every recorded visit is removed. URL bar suggestions backed by history will be empty until you visit pages again."
        ) {
          BrowsingHistory.shared.deleteAll()
        }

        resetRow(
          label: "Bookmarks",
          buttonTitle: "Clear",
          confirmTitle: "Delete all bookmarks?",
          confirmMessage:
            "Every bookmark and folder is removed. Use Export from a bookmarks manager beforehand if you might want them back."
        ) {
          Bookmarks.shared.deleteAll()
        }

        resetRow(
          label: "Downloads list",
          buttonTitle: "Clear",
          confirmTitle: "Clear download history?",
          confirmMessage:
            "Every download entry is removed from the list. The downloaded files on disk are not affected. Active transfers are cancelled."
        ) {
          // The store-only path would leave the manager's in-memory
          // entries array and KVO observations alive until the next
          // launch; sidebar listeners would keep reading stale rows.
          DownloadsManager.shared.clearAll()
        }

        resetRow(
          label: "Cache",
          buttonTitle: "Clear",
          confirmTitle: "Clear cached data?",
          confirmMessage:
            "Cached favicons are dropped immediately and re-fetch on next use. Filterlist downloads are deleted but the already-compiled rules stay live until the next launch."
        ) {
          FaviconCache.shared.clearAll()
          AdBlocker.shared.clearCache()
        }
      } header: {
        Text("Reset")
      } footer: {
        Text("These actions cannot be undone.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(isPresented: $showingAcknowledgements) {
      AcknowledgementsView()
    }
  }

  // MARK: - Reset

  /// Render one Reset row: label on the left, button on the right,
  /// click → confirmation alert (sheet-attached so Cancel returns
  /// focus to Settings) → on OK the destructive action runs.
  private func resetRow(
    label: String,
    buttonTitle: String,
    confirmTitle: String,
    confirmMessage: String,
    perform: @escaping () -> Void
  ) -> some View {
    HStack {
      Text(label)
      Spacer()
      Button(buttonTitle) {
        confirmReset(
          title: confirmTitle,
          message: confirmMessage,
          perform: perform)
      }
    }
  }

  private func confirmReset(
    title: String,
    message: String,
    perform: @escaping () -> Void
  ) {
    let alert = NSAlert()
    alert.messageText = title
    // Section-level footer already carries "These actions cannot be
    // undone."; the per-action alert sticks to the row-specific
    // detail so the same warning isn't displayed twice in one screen.
    alert.informativeText = message
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Reset")
    alert.addButton(withTitle: "Cancel")
    // First button (`.alertFirstButtonReturn`) is the destructive
    // action; AppKit marks it as the default which would otherwise
    // mean Return commits the destructive path. Demote default to
    // Cancel so a stray Return aborts.
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\r"
    guard let parent = SettingsWindowController.shared.window else {
      if alert.runModal() == .alertFirstButtonReturn {
        perform()
      }
      return
    }
    alert.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        if response == .alertFirstButtonReturn {
          perform()
        }
      }
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
