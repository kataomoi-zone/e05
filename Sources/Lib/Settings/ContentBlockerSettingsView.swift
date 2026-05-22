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
    case .whitelist: whitelistForm
    case .autoUpdate: autoUpdateForm
    }
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
    return AdBlocker.isSourceEnabled(source)
  }

  private func setEnabled(_ enabled: Bool, for source: AdBlocker.FilterSource) {
    PreferencesStore.shared.update { prefs in
      // Materialise the implicit-default set so the toggle becomes
      // explicit on every change. The collapse below converts it back
      // to `nil` whenever the result happens to match the default set.
      var list =
        prefs.adblockerEnabledSources
        ?? AdBlocker.allSources.filter(\.defaultEnabled).map(\.id)
      if enabled {
        if !list.contains(source.id) {
          list.append(source.id)
        }
      } else {
        list.removeAll { $0 == source.id }
      }
      // Collapse back to `nil` when the chosen set matches the default
      // set so the preferences.json stays small for the common case.
      if Set(list) == AdBlocker.defaultEnabledSourceIds {
        prefs.adblockerEnabledSources = nil
      } else {
        prefs.adblockerEnabledSources = list
      }
    }
    Task { await AdBlocker.shared.reload() }
  }

  // MARK: - Whitelist

  /// New-host TextField buffer. The store does not own this — it
  /// commits on Add only, so a half-typed entry never reaches disk.
  @State private var pendingHost: String = ""

  private var whitelistForm: some View {
    Form {
      Section {
        addRow
      } header: {
        Text("Add a Site")
      } footer: {
        Text(
          "Entries match the host and its subdomains. The same rules still apply on every other site."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        whitelistList
      } header: {
        HStack {
          Text("Whitelisted Sites")
          Spacer()
          if !whitelistHosts.isEmpty {
            Button("Remove All") { confirmRemoveAll() }
              .controlSize(.small)
          }
        }
      } footer: {
        Text(
          "Whitelisted hosts skip both the declarative rule list and the procedural cosmetic engine."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var addRow: some View {
    HStack {
      TextField("host (e.g. example.com)", text: $pendingHost)
        .textFieldStyle(.roundedBorder)
        .onSubmit { commitPendingHost() }
      Button("Add") { commitPendingHost() }
        .disabled(normalizedPendingHost.isEmpty)
    }
  }

  @ViewBuilder
  private var whitelistList: some View {
    if whitelistHosts.isEmpty {
      Text("No whitelisted sites yet.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ForEach(whitelistHosts, id: \.self) { host in
        HStack {
          Text(host)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer()
          Button {
            removeHost(host)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .help("Remove")
        }
      }
    }
  }

  private var whitelistHosts: [String] {
    _ = whitelistRevision
    return AdBlockerWhitelistStore.shared.allHosts
  }

  private var normalizedPendingHost: String {
    pendingHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  // Whitelist edits do not trigger `AdBlocker.reload()`: enforcement
  // runs per-pane through the `WKUserContentController` attach /
  // detach the live browser panes do on
  // ``AdBlockerWhitelistStore/didChangeNotification``, and the
  // procedural cosmetic engine checks the same store on every IPC.
  // Recompiling the rule list set would be wasted work.

  private func commitPendingHost() {
    let host = normalizedPendingHost
    guard !host.isEmpty else { return }
    AdBlockerWhitelistStore.shared.setWhitelisted(true, host: host)
    pendingHost = ""
    whitelistRevision &+= 1
  }

  private func removeHost(_ host: String) {
    AdBlockerWhitelistStore.shared.setWhitelisted(false, host: host)
    whitelistRevision &+= 1
  }

  private func confirmRemoveAll() {
    let alert = NSAlert()
    alert.messageText = "Remove all whitelisted sites?"
    alert.informativeText =
      "Every host on the list is forgotten. Block rules apply on those hosts again."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove All")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\r"
    guard let parent = SettingsWindowController.shared.window else { return }
    alert.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        guard response == .alertFirstButtonReturn else { return }
        AdBlockerWhitelistStore.shared.replaceAll(with: [])
        whitelistRevision &+= 1
      }
    }
  }

  // MARK: - Auto-Update

  private var autoUpdateForm: some View {
    Form {
      Section {
        Toggle(
          "Refresh filter lists automatically",
          isOn: Binding(
            get: { autoUpdateEnabled },
            set: { setAutoUpdate(enabled: $0) }
          )
        )
        if autoUpdateEnabled {
          Picker(
            "Frequency",
            selection: Binding(
              get: { currentInterval },
              set: { setInterval($0) }
            )
          ) {
            ForEach(UpdateInterval.allCases) { option in
              Text(option.displayName).tag(option)
            }
          }
        }
      } header: {
        Text("Schedule")
      } footer: {
        Text(lastUpdatedSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        Button("Refresh Now") {
          Task { await AdBlocker.shared.refreshFilterlists() }
        }
      } footer: {
        Text(
          "A manual refresh resets the cache and re-downloads every enabled list."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var autoUpdateEnabled: Bool {
    _ = revision
    let stored = PreferencesStore.shared.preferences.adblockerAutoUpdateIntervalHours
    return (stored ?? AdBlocker.defaultAutoUpdateIntervalHours) > 0
  }

  private var currentInterval: UpdateInterval {
    _ = revision
    let stored = PreferencesStore.shared.preferences.adblockerAutoUpdateIntervalHours
      ?? AdBlocker.defaultAutoUpdateIntervalHours
    return UpdateInterval.allCases.first { $0.rawValue == stored } ?? .weekly
  }

  private func setAutoUpdate(enabled: Bool) {
    PreferencesStore.shared.update { prefs in
      prefs.adblockerAutoUpdateIntervalHours =
        enabled ? AdBlocker.defaultAutoUpdateIntervalHours : 0
    }
  }

  private func setInterval(_ interval: UpdateInterval) {
    PreferencesStore.shared.update { prefs in
      prefs.adblockerAutoUpdateIntervalHours = interval.rawValue
    }
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

// MARK: - Update interval

private enum UpdateInterval: Int, CaseIterable, Identifiable, Hashable {
  case daily = 24
  case weekly = 168
  case monthly = 720

  var id: Int { rawValue }

  var displayName: String {
    switch self {
    case .daily: return "Every day"
    case .weekly: return "Every week"
    case .monthly: return "Every month"
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
