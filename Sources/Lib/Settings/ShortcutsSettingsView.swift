import AppKit
import SwiftUI

/// Shortcuts settings tab — lists every static action that lives in
/// the registry, grouped by ``ShortcutCategory``. Each row surfaces
/// the action's current effective key chord (override or default);
/// later commits attach the recorder + reset affordances + conflict
/// warnings.
@MainActor
struct ShortcutsSettingsView: View {
  @State private var category: ShortcutCategory = .panes
  /// Bumped on every preferences write so the detail re-resolves
  /// `actions()` against the new override dict.
  @State private var revision: Int = 0
  @State private var prefsListenerToken: UUID?

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
        ForEach(ShortcutCategory.allCases) { c in
          sidebarRow(c)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
    }
    .frame(width: 180)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func sidebarRow(_ c: ShortcutCategory) -> some View {
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
      Section {
        if currentRows.isEmpty {
          Text("No customisable actions in this category yet.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(currentRows, id: \.id) { row in
            shortcutRow(row)
          }
        }
      } header: {
        Text(category.title)
      } footer: {
        Text(
          "Terminal panes use their own key handling — adjust those in the ghostty config."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private func shortcutRow(_ row: ShortcutRow) -> some View {
    HStack {
      Text(row.title)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer()
      Text(row.keyLabel ?? "—")
        .foregroundStyle(row.keyLabel == nil ? .tertiary : .secondary)
        .monospaced()
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

  // MARK: - Rows

  /// Rows for the currently selected category, in the order pinned by
  /// ``ShortcutCategory/staticOrder``. Actions missing from the live
  /// registry (e.g. dynamically gated by feature flags later) drop
  /// silently rather than surface as ghost rows.
  private var currentRows: [ShortcutRow] {
    _ = revision  // touch dependency so the listener bump re-renders
    guard let pc = SettingsWindowController.shared.paneContainer else { return [] }
    let registry = Dictionary(
      uniqueKeysWithValues: pc.actions().map { ($0.id, $0) })
    let ids =
      ShortcutCategory.staticOrder
      .first(where: { $0.0 == category })?.1 ?? []
    return ids.compactMap { id -> ShortcutRow? in
      guard let action = registry[id] else { return nil }
      return ShortcutRow(
        id: id,
        title: action.title,
        keyLabel: action.keyLabel
      )
    }
  }
}

private struct ShortcutRow: Identifiable {
  let id: String
  let title: String
  let keyLabel: String?
}
