import AppKit
import SwiftUI

/// Shortcuts settings tab — lists every static action that lives in
/// the registry, grouped by ``ShortcutCategory``, and lets the user
/// record an override chord for any row. Esc cancels the recording,
/// Delete / Backspace clears the binding (renders as "—"), any
/// other chord persists immediately through ``PreferencesStore``.
@MainActor
struct ShortcutsSettingsView: View {
  @State private var category: ShortcutCategory = .panes
  /// Bumped on every preferences write so the detail re-resolves
  /// `actions()` against the new override dict.
  @State private var revision: Int = 0
  @State private var prefsListenerToken: UUID?
  /// Recorder state lives on a `class` so the `NSEvent` monitor
  /// closure can mutate it and trigger SwiftUI updates — a plain
  /// `@State` on the view struct cannot be written from inside the
  /// closure capture.
  @StateObject private var recorder = ShortcutRecorder()

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      detail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { subscribe() }
    .onDisappear {
      recorder.stop()
      unsubscribe()
    }
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
      recorder.stop()
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
        HStack {
          Text(category.title)
          Spacer()
          if hasAnyOverrides {
            Button("Reset All") { confirmResetAll() }
              .controlSize(.small)
          }
        }
      } footer: {
        Text(
          "Press Esc to cancel a recording, or Delete to clear the binding. Terminal panes use ghostty's own key handling."
            + (category == .browser
              ? " Back and Forward also respond to ⌘← / ⌘→ — those are handled by WebKit itself and can't be remapped."
              : "")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if !conflicts.isEmpty {
        Section {
          ForEach(conflicts) { c in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
              VStack(alignment: .leading, spacing: 1) {
                Text(c.chord)
                  .font(.system(size: 12, design: .monospaced))
                Text(c.actionTitles.joined(separator: " · "))
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        } header: {
          Text("Conflicts")
        } footer: {
          Text(
            "Two or more actions share the same chord. The first one in the menu wins; rebind the others to make them reachable."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
  }

  private func shortcutRow(_ row: ShortcutRow) -> some View {
    HStack(spacing: 6) {
      Text(row.title)
        .lineLimit(1)
        .truncationMode(.tail)
      if conflictingIds.contains(row.id) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help("Shares this chord with another action.")
      }
      Spacer()
      recorderButton(row)
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button("Reset to Default") {
        clearOverride(id: row.id)
      }
      .disabled(!row.hasOverride)
    }
  }

  /// Recorder affordance. Idle state shows the effective chord (or
  /// "—" when unbound); the active state shows "Type shortcut…" with
  /// an accent-coloured border so it reads as a focused field. A
  /// SwiftUI `Button` under `Form` swallows hit-testing on macOS
  /// 26, so dispatch goes through `.onTapGesture` on a
  /// `contentShape`-painted region instead. The label is split into
  /// three identity-separated branches because a single ternary
  /// `Text` reused across "recording" → "unbound" transitions
  /// occasionally renders blank — SwiftUI keeps the prior view's
  /// rendering when the body shape is identical.
  @ViewBuilder
  private func recorderLabel(for row: ShortcutRow, isRecording: Bool) -> some View {
    if isRecording {
      Text(verbatim: "Type shortcut…")
        .foregroundStyle(Color.accentColor)
    } else if let chord = row.effectiveLabel, !chord.isEmpty {
      Text(verbatim: chord)
        .foregroundStyle(Color.primary)
    } else {
      Text(verbatim: "—")
        .foregroundStyle(Color.secondary)
    }
  }

  private func recorderButton(_ row: ShortcutRow) -> some View {
    let isRecording = recorder.recordingId == row.id
    return recorderLabel(for: row, isRecording: isRecording)
      .font(.system(size: 12, design: .monospaced))
      .frame(width: 100, alignment: .center)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .stroke(
            isRecording ? Color.accentColor : Color.secondary.opacity(0.4),
            lineWidth: isRecording ? 1.5 : 1
          )
      )
      .contentShape(Rectangle())
      .onTapGesture {
        if isRecording {
          recorder.stop()
        } else {
          recorder.start(id: row.id) { binding in
            writeOverride(id: row.id, binding)
          }
        }
      }
  }

  private func writeOverride(id: String, _ binding: ShortcutBinding) {
    PreferencesStore.shared.update { prefs in
      var dict = prefs.keyboardShortcuts ?? [:]
      dict[id] = binding
      prefs.keyboardShortcuts = dict.isEmpty ? nil : dict
    }
  }

  private func clearOverride(id: String) {
    PreferencesStore.shared.update { prefs in
      var dict = prefs.keyboardShortcuts ?? [:]
      dict.removeValue(forKey: id)
      prefs.keyboardShortcuts = dict.isEmpty ? nil : dict
    }
  }

  private func confirmResetAll() {
    let alert = NSAlert()
    alert.messageText = "Reset all shortcuts?"
    alert.informativeText =
      "Every customised shortcut returns to its default. Unbound entries are restored too."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Reset All")
    alert.addButton(withTitle: "Cancel")
    // First button is destructive; demote default to Cancel so a
    // stray Return aborts (matches Sites tab + About tab resets).
    alert.buttons.first?.keyEquivalent = ""
    alert.buttons.last?.keyEquivalent = "\r"
    guard let parent = SettingsWindowController.shared.window else { return }
    alert.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        guard response == .alertFirstButtonReturn else { return }
        PreferencesStore.shared.update { $0.keyboardShortcuts = nil }
      }
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

  private var currentRows: [ShortcutRow] {
    _ = revision  // touch dependency so the listener bump re-renders
    guard let pc = SettingsWindowController.shared.paneContainer else { return [] }
    let registry = Dictionary(
      uniqueKeysWithValues: pc.actions().map { ($0.id, $0) })
    let overrides = PreferencesStore.shared.preferences.keyboardShortcuts ?? [:]
    let ids =
      ShortcutCategory.staticOrder
      .first(where: { $0.0 == category })?.1 ?? []
    return ids.compactMap { id -> ShortcutRow? in
      guard let action = registry[id] else { return nil }
      return ShortcutRow(
        id: id,
        title: action.title,
        effectiveKey: action.keyEquivalent,
        effectiveMask: action.modifierMask,
        hasOverride: overrides[id] != nil
      )
    }
  }

  // MARK: - Conflicts

  /// All static actions currently sharing a chord with another
  /// static action, resolved against the live registry. The bucketing
  /// itself lives in ``detectConflicts(in:)`` so it can be unit tested
  /// without the `SettingsWindowController` singleton; this property
  /// only supplies the live action list and re-resolves whenever
  /// `revision` bumps.
  private var conflicts: [ConflictGroup] {
    _ = revision
    guard let pc = SettingsWindowController.shared.paneContainer else { return [] }
    return Self.detectConflicts(in: pc.actions())
  }

  /// Bucket `actions` by their `(modifier, key)` chord and return
  /// every chord shared by two or more actions, sorted by the chord's
  /// glyph label. Dynamic registry entries (`workspace_switch_*`,
  /// `focus_pane_*`) are skipped — they are runtime generated and
  /// cannot be customised, so a "conflict" with them would never have
  /// a resolution. Pure over its input (no singleton / SwiftUI state),
  /// so the dynamic-exclusion, 2+-grouping and sort rules are unit
  /// testable.
  static func detectConflicts(in actions: [Action]) -> [ConflictGroup] {
    var buckets: [String: [(id: String, title: String, label: String)]] = [:]
    for action in actions {
      guard ShortcutCategory.category(for: action.id) != nil else { continue }
      guard let key = action.keyEquivalent else { continue }
      let bucket = "\(action.modifierMask.rawValue):\(key)"
      let label = Action.buildKeyLabel(key: key, mask: action.modifierMask) ?? key
      buckets[bucket, default: []].append((action.id, action.title, label))
    }
    return
      buckets
      .compactMap { (bucket, entries) -> ConflictGroup? in
        guard entries.count > 1 else { return nil }
        return ConflictGroup(
          id: bucket,
          chord: entries[0].label,
          actionIds: entries.map(\.id),
          actionTitles: entries.map(\.title)
        )
      }
      .sorted { $0.chord < $1.chord }
  }

  private var conflictingIds: Set<String> {
    Set(conflicts.flatMap { $0.actionIds })
  }

  private var hasAnyOverrides: Bool {
    !(PreferencesStore.shared.preferences.keyboardShortcuts?.isEmpty ?? true)
  }
}

// MARK: - Conflict

struct ConflictGroup: Identifiable, Equatable {
  let id: String
  let chord: String
  let actionIds: [String]
  let actionTitles: [String]
}

// MARK: - Recorder

/// Owns the `NSEvent.addLocalMonitorForEvents` lifetime and
/// translates keyDown events into chord overrides. A class instance
/// is necessary because the monitor closure has to mutate published
/// state — the view struct is value-typed and a snapshotted copy
/// cannot reach the backing store from a non-SwiftUI callback.
@MainActor
private final class ShortcutRecorder: ObservableObject {
  @Published var recordingId: String?
  private var monitor: Any?

  func start(id: String, onChord: @escaping (ShortcutBinding) -> Void) {
    stop()
    recordingId = id
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handle(event, onChord: onChord)
    }
  }

  func stop() {
    if let m = monitor {
      NSEvent.removeMonitor(m)
    }
    monitor = nil
    recordingId = nil
  }

  private func handle(_ event: NSEvent, onChord: (ShortcutBinding) -> Void) -> NSEvent? {
    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let chordMods = mods.subtracting([.capsLock])

    // Esc — abandon without changing anything.
    if event.keyCode == 0x35 {
      stop()
      return nil
    }

    // Modifier-less Delete / Backspace clears the binding so the user
    // can free a chord up. With a modifier the same key is recorded
    // as a real chord (e.g. ⌘⌫ for "Move to Trash") — Brave and Zen
    // settle on the same split.
    if (event.keyCode == 0x33 || event.keyCode == 0x75) && chordMods.isEmpty {
      onChord(ShortcutBinding(keyEquivalent: nil, modifierMask: 0))
      stop()
      return nil
    }

    // Pure modifier press (e.g. ⌘ alone). Swallow so the modifier
    // half-press does not register as an unbind.
    guard let key = Self.keyEquivalentString(from: event) else { return nil }

    // Persist `chordMods` (without CapsLock) so the chord matches
    // regardless of the user's CapsLock state at record time —
    // otherwise a record made with CapsLock on only dispatches
    // through NSMenu while CapsLock is on.
    onChord(ShortcutBinding(keyEquivalent: key, modifierMask: chordMods.rawValue))
    stop()
    return nil
  }

  /// Convert an NSEvent into the menu-style `keyEquivalent` string
  /// `Action` already understands. Returns `nil` for events that
  /// carry no usable character — modifier-only press, dead keys,
  /// function keys (Private-Use-Area glyphs that render blank in
  /// the system font), and any other control / non-printable
  /// character that NSMenu cannot match against a real key press.
  private static func keyEquivalentString(from event: NSEvent) -> String? {
    switch event.keyCode {
    case 0x30: return "\t"  // Tab
    case 0x24, 0x4C: return "\r"  // Return / numpad Enter
    case 0x31: return " "  // Space
    case 0x33: return "\u{8}"  // Backspace
    case 0x75: return "\u{7F}"  // Forward delete
    default:
      guard
        let chars = event.charactersIgnoringModifiers,
        let first = chars.first
      else { return nil }
      // Letter / number / punctuation / symbol covers everything
      // NSMenu will actually dispatch on. Function keys land in
      // the Cocoa PUA (`0xF700`-range) and pass `isASCII == false`,
      // so the printable-letter test rejects them.
      guard first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol else {
        return nil
      }
      return String(first).lowercased()
    }
  }
}

// MARK: - Row

private struct ShortcutRow: Identifiable {
  let id: String
  let title: String
  let effectiveKey: String?
  let effectiveMask: NSEvent.ModifierFlags
  let hasOverride: Bool

  var effectiveLabel: String? {
    Action.buildKeyLabel(key: effectiveKey, mask: effectiveMask)
  }
}
