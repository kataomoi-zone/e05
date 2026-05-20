import AppKit
import SwiftUI

/// Appearance settings tab — workspace accent palette plus pane
/// border presets. Each preset writes through to
/// ``PreferencesStore``; the active preset survives a restart and
/// applies live across every chrome surface.
@MainActor
struct AppearanceSettingsView: View {
  @State private var themePreset: ThemePreset
  @State private var accentPreset: AccentPalettePreset
  @State private var paneBorderWidthPreset: PaneBorderWidthPreset
  @State private var cornerPreset: CornerRadiusPreset
  @State private var listenerToken: UUID?

  init() {
    let prefs = PreferencesStore.shared.preferences
    _themePreset = State(initialValue: ThemePreset.resolve(prefs.theme))
    _accentPreset = State(
      initialValue: AccentPalettePreset.resolve(prefs.accentPalette))
    _paneBorderWidthPreset = State(
      initialValue: PaneBorderWidthPreset.resolve(prefs.paneBorderWidth))
    _cornerPreset = State(
      initialValue: CornerRadiusPreset.resolve(prefs.surfaceCornerRadius))
  }

  var body: some View {
    Form {
      themeSection
      workspaceAccentSection
      paneBorderSection
      surfaceCornersSection
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { subscribeToStore() }
    .onDisappear { unsubscribeFromStore() }
  }

  // MARK: - Theme

  private var themeSection: some View {
    Section {
      Picker("Theme", selection: $themePreset) {
        ForEach(ThemePreset.allCases) { preset in
          Label(preset.displayName, systemImage: preset.symbol).tag(preset)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .onChange(of: themePreset) { _, preset in
        PreferencesStore.shared.update { $0.theme = preset.rawValue }
      }
    } header: {
      Text("Theme")
    } footer: {
      Text(
        "System follows the macOS Appearance preference; Light and Dark override it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Workspace Accent

  private var workspaceAccentSection: some View {
    Section {
      Picker("Palette", selection: $accentPreset) {
        ForEach(AccentPalettePreset.allCases) { preset in
          accentRow(preset).tag(preset)
        }
      }
      .pickerStyle(.menu)
      .onChange(of: accentPreset) { _, preset in
        PreferencesStore.shared.update { $0.accentPalette = preset.rawValue }
      }

      // Always-visible swatch row for the selected preset so a user
      // who hasn't clicked the dropdown still sees the colors they
      // are about to map to workspaces.
      HStack(spacing: 6) {
        Text("Preview")
          .foregroundStyle(.secondary)
        Spacer()
        ForEach(Array(accentPreset.colors.enumerated()), id: \.offset) {
          _, color in
          Circle()
            .fill(Color(nsColor: color))
            .frame(width: 14, height: 14)
        }
      }
    } header: {
      Text("Workspace Accent")
    } footer: {
      Text("Workspace stripes pick up the new palette on the next switch.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func accentRow(_ preset: AccentPalettePreset) -> some View {
    HStack(spacing: 6) {
      Text(preset.displayName)
      ForEach(Array(preset.colors.enumerated()), id: \.offset) { _, color in
        Circle()
          .fill(Color(nsColor: color))
          .frame(width: 10, height: 10)
      }
    }
  }

  // MARK: - Pane Border (width only)

  private var paneBorderSection: some View {
    Section {
      Picker("Border width", selection: $paneBorderWidthPreset) {
        ForEach(PaneBorderWidthPreset.allCases) { preset in
          Text(preset.displayName).tag(preset)
        }
      }
      .pickerStyle(.menu)
      .onChange(of: paneBorderWidthPreset) { _, preset in
        PreferencesStore.shared.update {
          $0.paneBorderWidth = preset.rawValue
        }
      }
    } header: {
      Text("Pane Border")
    } footer: {
      Text("Width of the focused-pane outline.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Surface Corners (corner radius)

  private var surfaceCornersSection: some View {
    Section {
      Picker("Corner radius", selection: $cornerPreset) {
        ForEach(CornerRadiusPreset.allCases) { preset in
          Text(preset.displayName).tag(preset)
        }
      }
      .pickerStyle(.menu)
      .onChange(of: cornerPreset) { _, preset in
        PreferencesStore.shared.update {
          $0.surfaceCornerRadius = preset.rawValue
        }
      }
    } header: {
      Text("Surface Corners")
    } footer: {
      Text(
        "Applies to the pane container and chrome surfaces (find bar, palette, sidebar, suggestion list, URL bar dropdown)."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Store subscription

  /// Pull external mutations (Import / Reset / future tabs) into the
  /// view-local copies. Same pattern as `GeneralSettingsView` so
  /// changes from outside Appearance still rebind the pickers.
  private func subscribeToStore() {
    if listenerToken != nil { return }
    listenerToken = PreferencesStore.shared.addListener { new in
      themePreset = ThemePreset.resolve(new.theme)
      accentPreset = AccentPalettePreset.resolve(new.accentPalette)
      paneBorderWidthPreset = PaneBorderWidthPreset.resolve(
        new.paneBorderWidth)
      cornerPreset = CornerRadiusPreset.resolve(new.surfaceCornerRadius)
    }
  }

  private func unsubscribeFromStore() {
    if let token = listenerToken {
      PreferencesStore.shared.removeListener(token)
      listenerToken = nil
    }
  }
}
