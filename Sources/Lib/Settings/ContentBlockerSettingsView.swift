import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "ContentBlockerSettings")

/// Content Blocker settings tab — lets the user toggle individual
/// filter sources, maintain a per-host whitelist, and inspect / kick
/// the automatic filterlist update cadence. Follows the
/// ``SitesSettingsView`` shape (sub-sidebar + Divider + detail Form)
/// so the two host-list-style tabs paint identically.
@MainActor
struct ContentBlockerSettingsView: View {
  @State private var category: Category = .filterLists
  /// Bumped on every preferences write so the detail re-reads
  /// preferences-derived state (per-source enabled set, last-fetched
  /// timestamp, interval).
  @State private var revision: Int = 0
  @State private var prefsListenerToken: UUID?
  /// Bumped after `setWhitelisted` / `replaceAll` so the whitelist
  /// editor re-reads the store. The store has no listener API yet
  /// and the Settings tab is currently its only edit surface.
  @State private var whitelistRevision: Int = 0

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      detail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { subscribe() }
    .onDisappear { unsubscribe() }
  }

  // MARK: - Sub-sidebar

  private var sidebar: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Category.allCases) { c in
          sidebarRow(c)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .frame(width: 180)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func sidebarRow(_ c: Category) -> some View {
    Button {
      category = c
    } label: {
      HStack(spacing: 8) {
        Image(systemName: c.symbol).frame(width: 16)
        Text(c.title)
        Spacer()
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(c == category ? Color.primary.opacity(0.12) : .clear)
      .clipShape(RoundedRectangle(cornerRadius: 5))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    switch category {
    case .filterLists: filterListsForm
    default: placeholderForm
    }
  }

  private var placeholderForm: some View {
    Form {
      Section {
        Text("Per-category controls land in the next commit.")
          .foregroundStyle(.secondary)
      } header: {
        Text(category.title)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  // MARK: - Filter Lists

  private var filterListsForm: some View {
    Form {
      Section {
        ForEach(AdBlocker.allSources) { source in
          filterListRow(source)
        }
      } header: {
        HStack {
          Text(category.title)
          Spacer()
          Button("Refresh Now") {
            Task { await AdBlocker.shared.refreshFilterlists() }
          }
          .controlSize(.small)
        }
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text(lastUpdatedSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(
            "Disabling a list removes its rules on the next compile. The compiled binaries already attached to open tabs swap atomically — no reload is needed."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private func filterListRow(_ source: AdBlocker.FilterSource) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Toggle(
        isOn: Binding(
          get: { isEnabled(source) },
          set: { setEnabled($0, for: source) }
        )
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text(source.name)
          if let homepage = source.homepage {
            Button {
              openInPane(homepage)
            } label: {
              Text(homepage.host ?? homepage.absoluteString)
                .font(.caption)
            }
            .buttonStyle(.link)
          }
        }
      }
      .toggleStyle(.switch)
    }
  }

  /// Open `url` in a fresh e05 browser column rather than handing
  /// it off to the user's default browser. The Settings panel is
  /// left visible — the user can dismiss it manually after reading
  /// the linked page — but the main window is brought forward so
  /// the new column is actually in view.
  private func openInPane(_ url: URL) {
    guard let container = SettingsWindowController.shared.paneContainer else {
      logger.warning(
        "[settings/contentblocker] openInPane dropped: pane container not bound (url=\(url.absoluteString, privacy: .public))"
      )
      return
    }
    container.addColumn(address: PaneAddress(url))
    container.view.window?.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  // MARK: - Helpers

  /// Shared formatter — allocating a new instance on every body
  /// recomposition is expensive enough to be worth caching.
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()

  private var lastUpdatedSummary: String {
    _ = revision
    guard let date = PreferencesStore.shared.preferences.adblockerLastRefreshedAt
    else {
      return "Last updated: never (filterlists download on first launch)."
    }
    return
      "Last updated \(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))."
  }

  private func isEnabled(_ source: AdBlocker.FilterSource) -> Bool {
    _ = revision
    if let enabled = PreferencesStore.shared.preferences.adblockerEnabledSources {
      return enabled.contains(source.id)
    }
    return true
  }

  private func setEnabled(_ enabled: Bool, for source: AdBlocker.FilterSource) {
    PreferencesStore.shared.update { prefs in
      var list = prefs.adblockerEnabledSources
        ?? AdBlocker.allSources.map(\.id)
      if enabled {
        if !list.contains(source.id) {
          list.append(source.id)
        }
      } else {
        list.removeAll { $0 == source.id }
      }
      // Collapse back to `nil` when every shipped source is enabled
      // so the preferences.json stays small for the common case.
      let allIds = Set(AdBlocker.allSources.map(\.id))
      if Set(list) == allIds {
        prefs.adblockerEnabledSources = nil
      } else {
        prefs.adblockerEnabledSources = list
      }
    }
    Task { await AdBlocker.shared.reload() }
  }

  // MARK: - Subscription

  private func subscribe() {
    if prefsListenerToken != nil { return }
    prefsListenerToken = PreferencesStore.shared.addListener { _ in
      revision &+= 1
    }
  }

  private func unsubscribe() {
    if let token = prefsListenerToken {
      PreferencesStore.shared.removeListener(token)
      prefsListenerToken = nil
    }
  }
}

// MARK: - Category

private enum Category: String, CaseIterable, Identifiable {
  case filterLists
  case whitelist
  case autoUpdate

  var id: String { rawValue }

  var title: String {
    switch self {
    case .filterLists: return "Filter Lists"
    case .whitelist: return "Whitelist"
    case .autoUpdate: return "Auto-Update"
    }
  }

  var symbol: String {
    switch self {
    case .filterLists: return "list.bullet.rectangle"
    case .whitelist: return "checkmark.shield"
    case .autoUpdate: return "arrow.triangle.2.circlepath"
    }
  }
}
