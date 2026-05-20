import AppKit
import SwiftUI

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

  private var detail: some View {
    Form {
      Section {
        Text("Per-category controls land in the next commit.")
          .foregroundStyle(.secondary)
      } header: {
        Text(category.title)
      } footer: {
        Text(
          "Lists are downloaded under \(AdBlocker.cacheRoot.lastPathComponent)/ and refreshed on the schedule set above."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
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
