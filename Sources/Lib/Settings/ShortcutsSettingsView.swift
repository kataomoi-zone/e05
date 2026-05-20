import AppKit
import SwiftUI

/// Shortcuts settings tab — lets the user override the static key
/// chord for any registered ``Action``. The sub-sidebar selects a
/// ``ShortcutCategory`` and the detail lists every action assigned
/// to it; later commits will turn each row into a key-recorder
/// control and surface conflict warnings + a reset affordance.
@MainActor
struct ShortcutsSettingsView: View {
  @State private var category: ShortcutCategory = .panes

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      detail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Sub-sidebar

  /// Mirrors `SitesSettingsView`'s sub-sidebar so the two host-list
  /// tabs paint identically regardless of which side has keyboard
  /// focus. Native `List(.sidebar)` would swap selection colour with
  /// the outer settings sidebar, leaving the surfaces inconsistent.
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
        Text("Per-row controls land in the next commit.")
          .foregroundStyle(.secondary)
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
}
