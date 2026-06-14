import AppKit
import SwiftUI

/// Selectable kind for a `PaneWidthPreset` row in the Settings UI.
/// Kept separate from the persisted enum because the picker needs a
/// `Hashable` tag that survives a type flip while the row's numeric
/// value is being edited.
private enum PaneWidthPresetKind: String, Hashable, CaseIterable {
  case points
  case fraction
}

/// View-local representation of a single cycle-width preset row.
/// Carries a stable `id` for `ForEach`, the picker selection, and the
/// raw numeric value the user typed. The `points` branch reads the
/// value as points directly; the `fraction` branch interprets it as a
/// percentage (0-100) so the user sees `50` instead of `0.5` in the
/// field, then divides by 100 on write-back.
private struct WidthCycleRow: Identifiable, Equatable {
  let id: UUID
  var kind: PaneWidthPresetKind
  var value: Double

  init(id: UUID = UUID(), kind: PaneWidthPresetKind, value: Double) {
    self.id = id
    self.kind = kind
    self.value = value
  }

  init(preset: PaneWidthPreset) {
    self.id = UUID()
    switch preset {
    case .points(let p):
      self.kind = .points
      self.value = Double(p).rounded()
    case .fraction(let f):
      self.kind = .fraction
      self.value = (Double(f) * 100).rounded()
    }
  }

  var preset: PaneWidthPreset {
    let rounded = value.rounded()
    switch kind {
    case .points:
      return .points(CGFloat(rounded))
    case .fraction:
      return .fraction(CGFloat(rounded / 100))
    }
  }
}

/// Appearance settings tab — workspace accent palette plus pane
/// border presets. Each preset writes through to
/// ``PreferencesStore``; the active preset survives a restart and
/// applies live across every chrome surface.
@MainActor
struct AppearanceSettingsView: View {
  @State private var themePreset: ThemePreset
  @State private var accentPreset: AccentPalettePreset
  @State private var paneBorderWidthPreset: PaneBorderWidthPreset
  @State private var paneGapPreset: PaneGapPreset
  @State private var cornerPreset: CornerRadiusPreset
  @State private var widthCycleRows: [WidthCycleRow]
  @State private var listenerToken: UUID?

  init() {
    let prefs = PreferencesStore.shared.preferences
    _themePreset = State(initialValue: ThemePreset.resolve(prefs.theme))
    _accentPreset = State(
      initialValue: AccentPalettePreset.resolve(prefs.accentPalette))
    _paneBorderWidthPreset = State(
      initialValue: PaneBorderWidthPreset.resolve(prefs.paneBorderWidth))
    _paneGapPreset = State(initialValue: PaneGapPreset.resolve(prefs.paneGap))
    _cornerPreset = State(
      initialValue: CornerRadiusPreset.resolve(prefs.surfaceCornerRadius))
    let prefsCycle =
      prefs.widthCyclePresets
      ?? PaneContainerViewController.defaultWidthCycle
    _widthCycleRows = State(
      initialValue: prefsCycle.map { WidthCycleRow(preset: $0) })
  }

  var body: some View {
    Form {
      themeSection
      workspaceAccentSection
      paneBorderSection
      paneGapSection
      surfaceCornersSection
      widthCycleSection
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

  // MARK: - Pane Gap

  private var paneGapSection: some View {
    Section {
      Picker("Gap", selection: $paneGapPreset) {
        ForEach(PaneGapPreset.allCases) { preset in
          Text(preset.displayName).tag(preset)
        }
      }
      .pickerStyle(.menu)
      .onChange(of: paneGapPreset) { _, preset in
        PreferencesStore.shared.update { $0.paneGap = preset.rawValue }
      }
    } header: {
      Text("Pane Gap")
    } footer: {
      Text(
        "Spacing between panes, between columns, and around the workspace strip. Updates live across every open workspace."
      )
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

  // MARK: - Cycle Width Presets

  private var widthCycleSection: some View {
    Section {
      ForEach($widthCycleRows) { $row in
        widthCycleRowView(row: $row)
      }
      Button {
        addPreset()
      } label: {
        Label("Add Preset", systemImage: "plus")
      }
    } header: {
      Text("Cycle Width Presets")
    } footer: {
      Text(
        "Widths the Cycle Width action steps through. Points are taken literally and floored at the 450pt pane minimum on save; fractions multiply the visible workspace width and clamp to 10–100%."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func widthCycleRowView(row: Binding<WidthCycleRow>) -> some View {
    let id = row.wrappedValue.id
    let index = widthCycleRows.firstIndex(where: { $0.id == id }) ?? 0
    WidthCycleRowView(
      row: row,
      canRemove: widthCycleRows.count > 1,
      canMoveUp: index > 0,
      canMoveDown: index < widthCycleRows.count - 1,
      onMoveToTop: { moveToTop(rowId: id) },
      onMoveUp: { moveUp(rowId: id) },
      onMoveDown: { moveDown(rowId: id) },
      onMoveToBottom: { moveToBottom(rowId: id) },
      onRemove: { remove(rowId: id) },
      onCommit: writeBackPresets)
  }

  private func addPreset() {
    widthCycleRows.append(
      WidthCycleRow(
        kind: .points,
        value: Double(PaneContainerViewController.minPaneWidth)))
    writeBackPresets()
  }

  private func remove(rowId: UUID) {
    guard widthCycleRows.count > 1 else { return }
    widthCycleRows.removeAll { $0.id == rowId }
    writeBackPresets()
  }

  private func moveToTop(rowId: UUID) {
    guard let from = widthCycleRows.firstIndex(where: { $0.id == rowId }), from > 0
    else { return }
    let moved = widthCycleRows.remove(at: from)
    widthCycleRows.insert(moved, at: 0)
    writeBackPresets()
  }

  private func moveUp(rowId: UUID) {
    guard let from = widthCycleRows.firstIndex(where: { $0.id == rowId }), from > 0
    else { return }
    widthCycleRows.swapAt(from, from - 1)
    writeBackPresets()
  }

  private func moveDown(rowId: UUID) {
    guard let from = widthCycleRows.firstIndex(where: { $0.id == rowId }),
      from < widthCycleRows.count - 1
    else { return }
    widthCycleRows.swapAt(from, from + 1)
    writeBackPresets()
  }

  private func moveToBottom(rowId: UUID) {
    guard let from = widthCycleRows.firstIndex(where: { $0.id == rowId }),
      from < widthCycleRows.count - 1
    else { return }
    let moved = widthCycleRows.remove(at: from)
    widthCycleRows.append(moved)
    writeBackPresets()
  }

  private func writeBackPresets() {
    // Clamp each entry into its valid range so the visible field
    // reflects the value actually persisted. `.points` is floored at
    // the 450pt pane minimum (matching the `minimumWidthConstraint`
    // Auto Layout enforces); `.fraction` is clamped to 10–100% so
    // pathologically small values can't slip past the percentage UI
    // and over 100% is not a meaningful fraction of the workspace.
    let pointsFloor = Double(PaneContainerViewController.minPaneWidth)
    for idx in widthCycleRows.indices {
      let rounded = widthCycleRows[idx].value.rounded()
      switch widthCycleRows[idx].kind {
      case .points:
        widthCycleRows[idx].value = max(rounded, pointsFloor)
      case .fraction:
        widthCycleRows[idx].value = min(max(rounded, 10), 100)
      }
    }
    let presets = widthCycleRows.map(\.preset)
    PreferencesStore.shared.update { $0.widthCyclePresets = presets }
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
      paneGapPreset = PaneGapPreset.resolve(new.paneGap)
      cornerPreset = CornerRadiusPreset.resolve(new.surfaceCornerRadius)
      // Re-sync the cycle rows only when the persisted list actually
      // differs from what the view already shows. Otherwise an inline
      // edit (which writes through this view) would re-issue fresh
      // row ids on every keystroke, dropping TextField focus mid-typing.
      let externalPresets =
        new.widthCyclePresets
        ?? PaneContainerViewController.defaultWidthCycle
      let currentPresets = widthCycleRows.map(\.preset)
      if externalPresets != currentPresets {
        widthCycleRows = externalPresets.map { WidthCycleRow(preset: $0) }
      }
    }
  }

  private func unsubscribeFromStore() {
    if let token = listenerToken {
      PreferencesStore.shared.removeListener(token)
      listenerToken = nil
    }
  }
}

/// One inline row-action icon button (reorder / remove). A real
/// `Button` for the native hover highlight and click feedback. It stays
/// enabled even at the list edges — the action no-ops there — so `.help`
/// still surfaces a tooltip (SwiftUI on macOS drops help inside a
/// disabled `Button`); the edge state shows through reduced opacity, and
/// the hover highlight only appears while the action is live.
@MainActor
private struct RowActionButton: View {
  let symbol: String
  let help: String
  let enabled: Bool
  let action: () -> Void

  @State private var hovering = false

  var body: some View {
    Button {
      if enabled { action() }
    } label: {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .opacity(enabled ? 1 : 0.35)
        .frame(width: 24, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(hovering && enabled ? Color.secondary.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
  }
}

/// Single editable row inside the Cycle Width Presets section.
/// Lives in its own view so each row owns a `@FocusState` for the
/// TextField — focus loss commits the value back to preferences,
/// which is how the 450pt floor on `.points` becomes visible in the
/// field the instant the user clicks elsewhere instead of waiting on
/// the next Settings interaction.
@MainActor
private struct WidthCycleRowView: View {
  @Binding var row: WidthCycleRow
  let canRemove: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onMoveToTop: () -> Void
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void
  let onMoveToBottom: () -> Void
  let onRemove: () -> Void
  let onCommit: () -> Void

  @FocusState private var isValueFocused: Bool

  var body: some View {
    HStack {
      Picker("Type", selection: $row.kind) {
        Text("Points").tag(PaneWidthPresetKind.points)
        Text("Fraction").tag(PaneWidthPresetKind.fraction)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 160)
      .onChange(of: row.kind) { _, _ in onCommit() }

      TextField(
        "",
        value: $row.value,
        format: .number.precision(.fractionLength(0))
      )
      .textFieldStyle(.roundedBorder)
      .frame(width: 80)
      .focused($isValueFocused)
      .onSubmit { onCommit() }
      .onChange(of: isValueFocused) { _, focused in
        // Commit when the field loses focus so a user who clicks
        // elsewhere instead of pressing Return still sees the
        // 450pt floor applied to the visible number.
        if !focused { onCommit() }
      }

      Text(row.kind == .points ? "pt" : "%")
        .foregroundStyle(.secondary)
        .frame(width: 24, alignment: .leading)

      Spacer()

      // Inline row actions: the row has width to spare, so the reorder
      // and remove commands sit as a strip of icon buttons rather than
      // behind an ellipsis menu. Hover shows each one's tooltip even
      // while disabled (see `RowActionButton`).
      HStack(spacing: 2) {
        RowActionButton(
          symbol: "arrow.up.to.line", help: "Move to Top",
          enabled: canMoveUp, action: onMoveToTop)
        RowActionButton(
          symbol: "arrow.up", help: "Move Up",
          enabled: canMoveUp, action: onMoveUp)
        RowActionButton(
          symbol: "arrow.down", help: "Move Down",
          enabled: canMoveDown, action: onMoveDown)
        RowActionButton(
          symbol: "arrow.down.to.line", help: "Move to Bottom",
          enabled: canMoveDown, action: onMoveToBottom)
        RowActionButton(
          symbol: "trash",
          help: canRemove ? "Remove" : "Cycle Width needs at least one preset",
          enabled: canRemove, action: onRemove)
      }
    }
  }
}
