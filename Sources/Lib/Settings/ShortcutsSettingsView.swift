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
        Text(category.title)
      } footer: {
        Text(
          "Press Esc to cancel a recording, or Delete to clear the binding. Terminal panes use ghostty's own key handling."
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
      recorderButton(row)
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
