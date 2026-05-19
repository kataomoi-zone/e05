import AppKit
import SwiftUI

/// Sites settings tab — host-keyed state master view.
///
/// A sub-sidebar selects one of the categories; the detail renders
/// that category's host list with per-row actions. The underlying
/// stores (``MutedSitesStore``, ``PermissionsStore``,
/// ``SuspendHostExemptStore``) keep their independent files; this
/// view is the shared editing surface for all of them.
///
/// Suspend also surfaces the idle-suspend threshold from
/// ``E05Preferences`` because that setting answers the same
/// question — when the sweep runs, and for whom.
///
/// The sub-sidebar layout mirrors Safari's Websites preferences:
/// permission categories grow over time (autoplay, clipboard,
/// screen-sharing, pop-ups, ad-blocker) and a segmented control
/// would run out of horizontal room. A vertical list scales with
/// any number of categories.
@MainActor
struct SitesSettingsView: View {
  @State private var category: Category = .mute
  /// Bumped on every host-list mutation so the body re-queries the
  /// stores. The three site-state stores don't expose a listener
  /// API yet (Sites is currently their only edit surface), so a
  /// manual revision counter is the smallest hook that re-renders
  /// after `remove` / `setState` mutate the singleton in place.
  ///
  /// Why not a listener: a future palette action that mutates a
  /// host store while Sites is visible would leave the view
  /// rendering stale state until the next category switch. Wire
  /// `addListener` / `removeListener` onto each store at that
  /// point — the shape is already in `PreferencesStore`.
  @State private var revision: Int = 0
  /// View-local idle minutes. Seeded from preferences; `0` collapses
  /// to the 60-minute fallback display value because the off state
  /// is owned by ``idleSuspendEnabled`` so the minutes field always
  /// shows a sensible "what would the threshold be" value even
  /// while disabled.
  @State private var idleMinutes: Int
  /// Whether the idle sweep is enabled. Mapped to
  /// ``E05Preferences/suspendIdleMinutes`` as: `0` → off,
  /// `N > 0` → on with `N` minutes, `nil` → on with the 60-minute
  /// fallback. Splitting the toggle from the minutes makes the off
  /// state explicit instead of overloading `0`.
  @State private var idleSuspendEnabled: Bool
  @State private var prefsListenerToken: UUID?

  init() {
    let prefs = PreferencesStore.shared.preferences
    let stored = prefs.suspendIdleMinutes
    _idleMinutes = State(initialValue: (stored ?? 60) > 0 ? (stored ?? 60) : 60)
    _idleSuspendEnabled = State(initialValue: (stored ?? 60) > 0)
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      detail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { subscribePreferences() }
    .onDisappear { unsubscribePreferences() }
  }

  // MARK: - Sub-sidebar

  /// Custom row stack rather than `List(.sidebar)` so the visual
  /// matches the outer Settings sidebar regardless of which side has
  /// keyboard focus. The native `.sidebar` style switches between
  /// "blue accent (focused)" and "grey (unfocused)" selection paint
  /// — the outer sidebar always renders unfocused because the user's
  /// last interaction lives in the inner list, leaving the two
  /// surfaces looking inconsistent. Custom buttons settle on the
  /// outer "unfocused" look so both surfaces match.
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

  private var detail: some View {
    Form {
      if category == .suspend {
        idleSection
      }

      Section {
        hostListBody
      } header: {
        HStack {
          Text(category.listHeader)
          Spacer()
          if !currentHosts.isEmpty {
            Button("Remove All") { confirmRemoveAll() }
              .controlSize(.small)
          }
        }
      } footer: {
        Text(category.footerHint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  // MARK: - Host list

  /// Render the current category's host list, or an empty-state
  /// placeholder when nothing has been recorded yet. Each row pairs
  /// the host with the state control appropriate for the category —
  /// permission categories expose Allow/Deny pickers, mute and
  /// suspend expose only a remove button because their state is
  /// binary "host is on the list".
  @ViewBuilder
  private var hostListBody: some View {
    let hosts = currentHosts
    if hosts.isEmpty {
      Text(category.emptyMessage)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    } else {
      ForEach(hosts, id: \.self) { host in
        hostRow(host)
      }
    }
  }

  @ViewBuilder
  private func hostRow(_ host: String) -> some View {
    HStack {
      Text(host)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      if let kind = category.permissionKind {
        permissionPicker(host: host, kind: kind)
      }
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

  @ViewBuilder
  private func permissionPicker(host: String, kind: PermissionKind) -> some View {
    // `currentHosts` already filters to rows where `state(for:kind:)`
    // resolves, so the optional unwrap is total at this site. Bind
    // through `if let` rather than a `?? .grant` fallback so a
    // future caller that skips the filter surfaces the bug instead
    // of silently coercing every row to Allow.
    if let current = PermissionsStore.shared.state(for: host, kind: kind) {
      Picker(
        "",
        selection: Binding(
          get: { current },
          set: { newValue in
            PermissionsStore.shared.setState(newValue, for: host, kind: kind)
            revision += 1
          })
      ) {
        Text("Allow").tag(PermissionState.grant)
        Text("Deny").tag(PermissionState.deny)
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 80)
    }
  }

  // MARK: - Idle suspend section

  private var idleSection: some View {
    Section {
      Toggle("Suspend idle panes after a delay", isOn: $idleSuspendEnabled)
        .onChange(of: idleSuspendEnabled) { _, enabled in
          let value: Int = enabled ? max(1, idleMinutes) : 0
          PreferencesStore.shared.update { $0.suspendIdleMinutes = value }
        }
      if idleSuspendEnabled {
        HStack {
          Text("Inactivity threshold")
          Spacer()
          TextField("", value: $idleMinutes, format: .number)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(width: 60)
            .multilineTextAlignment(.trailing)
          Stepper("", value: $idleMinutes, in: 1...600).labelsHidden()
          Text("minutes").foregroundStyle(.secondary)
        }
        .onChange(of: idleMinutes) { _, raw in
          // Clamp out-of-range input before writing back. The
          // Stepper respects 1...600 by itself; direct TextField
          // entry can still land outside, so reassign and let the
          // re-fire pick up the persist branch.
          let clamped = max(1, min(600, raw))
          if clamped == raw {
            PreferencesStore.shared.update { $0.suspendIdleMinutes = clamped }
          } else {
            idleMinutes = clamped
          }
        }
      }
    } header: {
      Text("Idle Suspend")
    } footer: {
      Text(
        "Memory-pressure suspends still run when the idle sweep is off."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Store subscription

  private func subscribePreferences() {
    if prefsListenerToken != nil { return }
    prefsListenerToken = PreferencesStore.shared.addListener { new in
      let stored = new.suspendIdleMinutes
      idleSuspendEnabled = (stored ?? 60) > 0
      if let s = stored, s > 0 {
        idleMinutes = s
      } else if stored == nil {
        idleMinutes = 60
      }
    }
  }

  private func unsubscribePreferences() {
    if let token = prefsListenerToken {
      PreferencesStore.shared.removeListener(token)
      prefsListenerToken = nil
    }
  }

  // MARK: - Hosts

  /// Current category's host list, sorted for stable rendering. The
  /// underlying stores all return sorted arrays so this is just a
  /// dispatch table.
  private var currentHosts: [String] {
    // Touch `revision` so the dependency tracker re-runs the
    // computation after every mutation. Without the read SwiftUI
    // would memoise the previous list and the new entry would not
    // surface until the picker triggers a separate render.
    _ = revision
    switch category {
    case .mute: return MutedSitesStore.shared.allHosts
    case .camera, .microphone, .location, .notifications:
      guard let kind = category.permissionKind else { return [] }
      return PermissionsStore.shared.allHosts.filter {
        PermissionsStore.shared.state(for: $0, kind: kind) != nil
      }
    case .suspend: return SuspendHostExemptStore.shared.allHosts
    }
  }

  private func removeHost(_ host: String) {
    switch category {
    case .mute:
      MutedSitesStore.shared.setMuted(false, host: host)
    case .camera, .microphone, .location, .notifications:
      if let kind = category.permissionKind {
        PermissionsStore.shared.clear(host: host, kind: kind)
      }
    case .suspend:
      SuspendHostExemptStore.shared.remove(host: host)
    }
    revision += 1
  }

  // MARK: - Bulk actions

  private func confirmRemoveAll() {
    let alert = NSAlert()
    alert.messageText = category.removeAllTitle
    alert.informativeText = category.removeAllMessage
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Remove All")
    alert.addButton(withTitle: "Cancel")
    // First button is destructive; demote default to Cancel so a
    // stray Return aborts (same pattern as the About tab's resets).
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\r"
    guard let parent = SettingsWindowController.shared.window else { return }
    alert.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        guard response == .alertFirstButtonReturn else { return }
        removeAllCurrent()
      }
    }
  }

  private func removeAllCurrent() {
    for host in currentHosts { removeHost(host) }
  }
}

// MARK: - Category metadata

/// Master-view categories driven by the sub-sidebar. Permission
/// categories map to a ``PermissionKind`` so the row builder can
/// read and write the right key without a per-category switch. New
/// permission kinds (autoplay, clipboard, screen-sharing, pop-ups,
/// ad-blocker) land here by adding a case + a metadata row each.
private enum Category: String, CaseIterable, Identifiable {
  case mute
  case camera
  case microphone
  case location
  case notifications
  case suspend

  var id: String { rawValue }

  var title: String {
    switch self {
    case .mute: "Mute"
    case .camera: "Camera"
    case .microphone: "Microphone"
    case .location: "Location"
    case .notifications: "Notifications"
    case .suspend: "Suspend"
    }
  }

  /// SF Symbol shown next to the title in the sub-sidebar. Picked
  /// so the symbol vocabulary tracks Apple's own privacy / power
  /// surfaces (speaker.slash for mute, video for camera, etc.).
  var symbol: String {
    switch self {
    case .mute: "speaker.slash"
    case .camera: "video"
    case .microphone: "mic"
    case .location: "location"
    case .notifications: "bell"
    case .suspend: "moon.zzz"
    }
  }

  var listHeader: String {
    switch self {
    case .mute: "Muted Sites"
    case .camera: "Camera Access"
    case .microphone: "Microphone Access"
    case .location: "Location Access"
    case .notifications: "Notifications"
    case .suspend: "Never Suspend"
    }
  }

  var footerHint: String {
    switch self {
    case .mute:
      "Listed hosts are muted on every page load."
    case .camera, .microphone, .location, .notifications:
      "Hosts choose between Allow and Deny. Remove a host to be prompted again on its next request."
    case .suspend:
      "Listed hosts skip the automatic idle suspend sweep."
    }
  }

  var emptyMessage: String {
    switch self {
    case .mute: "No muted sites yet."
    case .camera: "No camera decisions recorded yet."
    case .microphone: "No microphone decisions recorded yet."
    case .location: "No location decisions recorded yet."
    case .notifications: "No notification decisions recorded yet."
    case .suspend: "No sites are excluded from auto-suspend."
    }
  }

  var removeAllTitle: String {
    switch self {
    case .mute: "Remove all muted sites?"
    case .camera: "Clear all camera decisions?"
    case .microphone: "Clear all microphone decisions?"
    case .location: "Clear all location decisions?"
    case .notifications: "Clear all notification decisions?"
    case .suspend: "Remove all never-suspend sites?"
    }
  }

  var removeAllMessage: String {
    switch self {
    case .mute:
      "Every muted site returns to its default audio behaviour."
    case .camera, .microphone, .location, .notifications:
      "Every host in this list is forgotten. The next request from any of them prompts you again."
    case .suspend:
      "Every host in this list returns to the default suspend behaviour."
    }
  }

  /// `nil` for the binary categories (mute, suspend) — only the
  /// permission categories have a tri-state grant/deny/ask
  /// dimension to expose.
  var permissionKind: PermissionKind? {
    switch self {
    case .camera: .camera
    case .microphone: .microphone
    case .location: .geolocation
    case .notifications: .notification
    case .mute, .suspend: nil
    }
  }
}
