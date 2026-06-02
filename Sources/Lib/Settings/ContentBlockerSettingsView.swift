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

  @State private var showAddRow = false
  @State private var newSourceName = ""
  @State private var newSourceURL = ""
  @State private var newSourceHomepage = ""

  private var filterListsForm: some View {
    Form {
      defaultListsSection
      optionalListsSection
      customListsSection
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private var defaultListsSection: some View {
    Section {
      ForEach(coreBuiltInSources) { source in
        filterListRow(source, removable: false)
      }
    } header: {
      HStack {
        Text("Default Lists")
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

  private var optionalListsSection: some View {
    Section {
      ForEach(optionalBuiltInSources) { source in
        filterListRow(source, removable: false)
      }
    } header: {
      Text("Optional Lists")
    } footer: {
      Text(
        "Off by default. Enabling a list fetches and compiles it on the next reload."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var customListsSection: some View {
    Section {
      let rows = customRows
      if rows.isEmpty && !showAddRow {
        Text("No custom lists yet.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ForEach(rows) { source in
          filterListRow(source, removable: true)
        }
      }
      if showAddRow { addCustomRow }
    } header: {
      HStack {
        Text("Custom Filter URLs")
        Spacer()
        if !showAddRow {
          Button("Add…") { showAddRow = true }
            .controlSize(.small)
        }
      }
    } footer: {
      Text(
        "Add lists from sources you trust. URLs fetch directly; e05 does not verify content."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var coreBuiltInSources: [AdBlocker.FilterSource] {
    AdBlocker.builtInSources.filter { $0.category == .core }
  }

  private var optionalBuiltInSources: [AdBlocker.FilterSource] {
    AdBlocker.builtInSources.filter { $0.category == .optional }
  }

  private var customRows: [AdBlocker.FilterSource] {
    _ = revision
    return AdBlocker.customSources()
  }

  private func filterListRow(
    _ source: AdBlocker.FilterSource, removable: Bool
  ) -> some View {
    let isCustom = source.id.hasPrefix(AdBlocker.customSourceIdPrefix)
    return HStack(alignment: .firstTextBaseline) {
      Toggle(
        isOn: Binding(
          get: { isEnabled(source) },
          set: { setEnabled($0, for: source) }
        )
      ) {
        VStack(alignment: .leading, spacing: 2) {
          Text(source.name)
          // Built-in rows surface only the homepage (the upstream
          // project page is the right credit link). Custom rows also
          // show the filterlist URL itself so the user can audit
          // exactly what was added — homepage is optional and the URL
          // is the actual fetched bytes.
          if isCustom {
            Button {
              openInPane(source.url)
            } label: {
              Text(source.url.absoluteString)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .buttonStyle(.link)
          }
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
      if removable {
        Button {
          confirmRemoveCustom(source)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Remove")
      }
    }
  }

  // MARK: - Custom Source Add Row

  /// Inline expansion shown when the user clicks "Add…". Avoids
  /// SwiftUI `.sheet` on the Settings NSPanel — that combination
  /// leaves the second presentation as a transparent grey overlay
  /// with no visible content on macOS 26.
  private var addCustomRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Name", text: $newSourceName)
        .textFieldStyle(.roundedBorder)
      TextField("URL (https://...)", text: $newSourceURL)
        .textFieldStyle(.roundedBorder)
      TextField("Homepage (optional)", text: $newSourceHomepage)
        .textFieldStyle(.roundedBorder)
      if let message = addValidation.1 {
        Text(message)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { closeAddRow() }
          .keyboardShortcut(.cancelAction)
        Button("Add") { commitNewCustomSource() }
          .keyboardShortcut(.defaultAction)
          .disabled(!addValidation.0)
      }
    }
    .padding(.vertical, 4)
  }

  /// (canAdd, errorMessage) — empty inputs return `(false, nil)` so the
  /// sheet does not shout at the user before they have typed anything.
  private var addValidation: (Bool, String?) {
    let name = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let urlString = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !urlString.isEmpty else { return (false, nil) }
    guard let url = URL(string: urlString),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else {
      return (false, "URL must start with http:// or https:// and include a host.")
    }
    let existing = PreferencesStore.shared.preferences.adblockerCustomSources ?? []
    if existing.contains(where: { $0.url == urlString }) {
      return (false, "This URL is already in the list.")
    }
    return (true, nil)
  }

  private func commitNewCustomSource() {
    let name = newSourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let urlString = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let homepageRaw = newSourceHomepage.trimmingCharacters(in: .whitespacesAndNewlines)
    let homepage = homepageRaw.isEmpty ? nil : homepageRaw
    let entry = AdblockerCustomSource(
      id: ULID().string,
      name: name,
      url: urlString,
      homepage: homepage
    )
    let entryRuntimeID = "\(AdBlocker.customSourceIdPrefix)\(entry.id)"
    PreferencesStore.shared.update { prefs in
      var customs = prefs.adblockerCustomSources ?? []
      customs.append(entry)
      prefs.adblockerCustomSources = customs
      // When the user already has an explicit enable list, append the
      // new id so the just-added list starts on. With the implicit
      // (nil) set, customs default-enable for free.
      if var enabled = prefs.adblockerEnabledSources {
        enabled.append(entryRuntimeID)
        prefs.adblockerEnabledSources = enabled
      }
    }
    closeAddRow()
    Task { await AdBlocker.shared.reload() }
  }

  private func closeAddRow() {
    showAddRow = false
    newSourceName = ""
    newSourceURL = ""
    newSourceHomepage = ""
  }

  private func confirmRemoveCustom(_ source: AdBlocker.FilterSource) {
    let alert = NSAlert()
    alert.messageText = "Remove “\(source.name)” from custom filter lists?"
    alert.informativeText =
      "Block rules from this list stop applying on the next reload."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\r"
    guard let parent = SettingsWindowController.shared.window else { return }
    alert.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        guard response == .alertFirstButtonReturn else { return }
        removeCustom(source)
      }
    }
  }

  private func removeCustom(_ source: AdBlocker.FilterSource) {
    let customID = String(source.id.dropFirst(AdBlocker.customSourceIdPrefix.count))
    PreferencesStore.shared.update { prefs in
      var customs = prefs.adblockerCustomSources ?? []
      customs.removeAll { $0.id == customID }
      prefs.adblockerCustomSources = customs.isEmpty ? nil : customs
      if var enabled = prefs.adblockerEnabledSources {
        enabled.removeAll { $0 == source.id }
        prefs.adblockerEnabledSources = enabled
      }
    }
    // Drop the orphan cache file so the cache dir does not accumulate
    // text from sources the user has removed.
    let cacheURL = AdBlocker.cacheRoot.appendingPathComponent(source.cacheFilename)
    do {
      try FileManager.default.removeItem(at: cacheURL)
    } catch CocoaError.fileNoSuchFile {
      // The cache may legitimately be absent if the source was added
      // but never compiled (e.g. removed before the first reload).
    } catch {
      logger.warning(
        "[settings/contentblocker] failed to drop custom cache \(cacheURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    Task { await AdBlocker.shared.reload() }
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
    let stored =
      PreferencesStore.shared.preferences.adblockerAutoUpdateIntervalHours
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
