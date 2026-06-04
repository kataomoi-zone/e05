import AppKit
import Foundation
import Testing

@testable import E05Lib

@Suite("ShortcutBinding")
struct ShortcutBindingTests {
  @Test("Codable round-trip preserves both fields")
  func codableRoundTrip() throws {
    let binding = ShortcutBinding(
      keyEquivalent: "k", modifierMask: NSEvent.ModifierFlags.command.rawValue)
    let data = try JSONEncoder().encode(binding)
    let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
    #expect(decoded == binding)
  }

  @Test("Codable encodes the unbound form with keyEquivalent nil")
  func unboundIsRepresentable() throws {
    let binding = ShortcutBinding(keyEquivalent: nil, modifierMask: 0)
    let data = try JSONEncoder().encode(binding)
    let decoded = try JSONDecoder().decode(ShortcutBinding.self, from: data)
    #expect(decoded.keyEquivalent == nil)
    #expect(decoded.modifierMask == 0)
  }
}

@Suite("Action.applyingOverride")
@MainActor
struct ActionApplyingOverrideTests {
  private func make(key: String? = "h", mask: NSEvent.ModifierFlags = [.command]) -> Action {
    Action(id: "test", title: "Test", keyEquivalent: key, modifierMask: mask, handler: {})
  }

  @Test("nil override returns the same action")
  func nilOverrideIsIdentity() {
    let action = make()
    let resolved = action.applyingOverride(nil)
    #expect(resolved.keyEquivalent == "h")
    #expect(resolved.modifierMask == [.command])
    #expect(resolved.keyLabel == "⌘H")
  }

  @Test("override swaps key and mask and rebuilds the label")
  func overrideReplacesChord() {
    let action = make()
    let resolved = action.applyingOverride(
      ShortcutBinding(
        keyEquivalent: "j",
        modifierMask: NSEvent.ModifierFlags([.command, .shift]).rawValue))
    #expect(resolved.keyEquivalent == "j")
    #expect(resolved.modifierMask == [.command, .shift])
    #expect(resolved.keyLabel == "⇧⌘J")
  }

  @Test("override with nil key unbinds the action")
  func overrideCanUnbind() {
    let action = make()
    let resolved = action.applyingOverride(
      ShortcutBinding(keyEquivalent: nil, modifierMask: 0))
    #expect(resolved.keyEquivalent == nil)
    #expect(resolved.keyLabel == nil)
  }

  @Test("override masks bits outside .deviceIndependentFlagsMask")
  func overrideMasksRawBits() {
    let action = make()
    // Pass a mask that pairs `.command` with a device-dependent
    // bit (the lower 16 bits of NSEvent.ModifierFlags are reserved
    // for hardware-specific flags). The applyingOverride helper
    // must strip those so they don't leak into
    // NSMenuItem.keyEquivalentModifierMask.
    let rawWithJunk = NSEvent.ModifierFlags.command.rawValue | 0x0000_0100
    let resolved = action.applyingOverride(
      ShortcutBinding(keyEquivalent: "k", modifierMask: rawWithJunk))
    #expect(resolved.modifierMask == [.command])
  }

  @Test("Action.buildKeyLabel handles special key glyphs")
  func specialKeyGlyphsRendered() {
    #expect(Action.buildKeyLabel(key: "\u{8}", mask: [.command]) == "⌘⌫")
    #expect(Action.buildKeyLabel(key: "\t", mask: [.control]) == "⌃⇥")
    #expect(Action.buildKeyLabel(key: " ", mask: [.command, .option]) == "⌥⌘␣")
    #expect(Action.buildKeyLabel(key: nil, mask: [.command]) == nil)
  }
}

@Suite("ShortcutCategory")
struct ShortcutCategoryTests {
  @Test("category(for:) returns the matching bucket for static ids")
  func staticIdsMapToCategories() {
    #expect(ShortcutCategory.category(for: "close_pane") == .panes)
    #expect(ShortcutCategory.category(for: "focus_right") == .focus)
    #expect(ShortcutCategory.category(for: "pane_find") == .findURL)
    #expect(ShortcutCategory.category(for: "focus_url_bar") == .findURL)
    #expect(ShortcutCategory.category(for: "browser_back") == .browser)
    #expect(ShortcutCategory.category(for: "new_folder") == .finder)
    #expect(ShortcutCategory.category(for: "open_settings") == .window)
    #expect(ShortcutCategory.category(for: "workspace_new") == .workspace)
  }

  @Test("category(for:) returns nil for dynamic ids")
  func dynamicIdsAreSkipped() {
    #expect(ShortcutCategory.category(for: "workspace_switch_abc") == nil)
    #expect(ShortcutCategory.category(for: "workspace_move_pane_xyz") == nil)
    #expect(ShortcutCategory.category(for: "focus_pane_123") == nil)
  }

  @Test("staticOrder ids are unique across categories")
  func staticOrderIdsAreUnique() {
    let all = ShortcutCategory.staticOrder.flatMap(\.1)
    #expect(Set(all).count == all.count, "duplicate id in staticOrder: \(all)")
  }

  @Test("every static order entry resolves to its declared category")
  func staticOrderRoundTrip() {
    for (category, ids) in ShortcutCategory.staticOrder {
      for id in ids {
        #expect(
          ShortcutCategory.category(for: id) == category,
          "id \(id) declared under \(category) but resolves to \(String(describing: ShortcutCategory.category(for: id)))"
        )
      }
    }
  }
}

@Suite("ShortcutsSettingsView.detectConflicts")
@MainActor
struct ShortcutConflictDetectionTests {
  private func action(
    _ id: String, _ key: String?, _ mask: NSEvent.ModifierFlags = [.command]
  ) -> Action {
    Action(id: id, title: id, keyEquivalent: key, modifierMask: mask, handler: {})
  }

  @Test("two static actions on the same chord form one conflict group")
  func sharedChordGroups() {
    let groups = ShortcutsSettingsView.detectConflicts(in: [
      action("close_pane", "w"),
      action("focus_right", "w"),
    ])
    #expect(groups.count == 1)
    #expect(groups[0].chord == "⌘W")
    #expect(Set(groups[0].actionIds) == ["close_pane", "focus_right"])
  }

  @Test("dynamic registry ids never count toward a conflict")
  func dynamicIdsExcluded() {
    // focus_pane_123 shares ⌘W with close_pane, but dynamic ids are
    // runtime-generated and uncustomisable, so the bucket holds only
    // the one static action and reports no conflict.
    let groups = ShortcutsSettingsView.detectConflicts(in: [
      action("close_pane", "w"),
      action("focus_pane_123", "w"),
    ])
    #expect(groups.isEmpty)
  }

  @Test("unbound actions (nil key) are not conflicts")
  func unboundExcluded() {
    let groups = ShortcutsSettingsView.detectConflicts(in: [
      action("close_pane", nil),
      action("focus_right", nil),
    ])
    #expect(groups.isEmpty)
  }

  @Test("distinct chords produce no conflict")
  func distinctChords() {
    let groups = ShortcutsSettingsView.detectConflicts(in: [
      action("close_pane", "w"),
      action("focus_right", "e"),
    ])
    #expect(groups.isEmpty)
  }

  @Test("the same key under different modifiers is not a conflict")
  func modifierDistinguishesChord() {
    let groups = ShortcutsSettingsView.detectConflicts(in: [
      action("close_pane", "l", [.command]),
      action("focus_right", "l", [.command, .option]),
    ])
    #expect(groups.isEmpty)
  }

  @Test("conflict groups are sorted by chord glyph")
  func groupsSortedByChord() {
    let groups = ShortcutsSettingsView.detectConflicts(in: [
      action("close_pane", "z"),
      action("focus_right", "z"),
      action("pane_find", "a"),
      action("browser_back", "a"),
    ])
    #expect(groups.map(\.chord) == ["⌘A", "⌘Z"])
  }

  @Test("three actions on one chord collapse into a single group")
  func threeWayChordGroups() {
    let groups = ShortcutsSettingsView.detectConflicts(in: [
      action("close_pane", "g"),
      action("focus_right", "g"),
      action("pane_find", "g"),
    ])
    #expect(groups.count == 1)
    #expect(Set(groups[0].actionIds) == ["close_pane", "focus_right", "pane_find"])
  }

  @Test("an empty action list yields no conflicts")
  func emptyInput() {
    #expect(ShortcutsSettingsView.detectConflicts(in: []).isEmpty)
  }

  @Test("a conflict group preserves input order in its ids and titles")
  func groupPreservesOrderAndTitles() {
    // Drive the whole ConflictGroup through `==` (not field-by-field)
    // so the bucket id, chord glyph, and the input-order-preserving
    // id / title arrays are all pinned at once.
    let cmd = NSEvent.ModifierFlags.command.rawValue
    let groups = ShortcutsSettingsView.detectConflicts(in: [
      Action(
        id: "close_pane", title: "Close Pane", keyEquivalent: "w",
        modifierMask: [.command], handler: {}),
      Action(
        id: "focus_right", title: "Focus Right", keyEquivalent: "w",
        modifierMask: [.command], handler: {}),
    ])
    #expect(
      groups == [
        ConflictGroup(
          id: "\(cmd):w",
          chord: "⌘W",
          actionIds: ["close_pane", "focus_right"],
          actionTitles: ["Close Pane", "Focus Right"])
      ])
  }
}

@Suite("Shortcut override preferences fan-out")
@MainActor
struct ShortcutPreferencesTests {
  private func withTempStoreURL(_ body: (URL) throws -> Void) rethrows {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShortcutsTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
      at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try body(dir.appendingPathComponent("preferences.json"))
  }

  @Test("PreferencesStore round-trip preserves the override dict")
  func roundTripOverrides() throws {
    try withTempStoreURL { storeURL in
      let writer = PreferencesStore(storeURL: storeURL)
      writer.update {
        $0.keyboardShortcuts = [
          "close_pane": ShortcutBinding(
            keyEquivalent: "x",
            modifierMask: NSEvent.ModifierFlags([.command, .shift]).rawValue),
          "browser_reload": ShortcutBinding(keyEquivalent: nil, modifierMask: 0),
        ]
      }

      let reader = PreferencesStore(storeURL: storeURL)
      let overrides = reader.preferences.keyboardShortcuts ?? [:]
      #expect(overrides["close_pane"]?.keyEquivalent == "x")
      #expect(
        overrides["close_pane"]?.modifierMask
          == NSEvent.ModifierFlags([.command, .shift]).rawValue)
      #expect(overrides["browser_reload"]?.keyEquivalent == nil)
    }
  }

  @Test("older preferences files without keyboardShortcuts still decode")
  func legacyDecodeCompatibility() throws {
    try withTempStoreURL { storeURL in
      let legacy = """
        {
          "version": 1,
          "preferences": {
            "searchTemplate": "https://duckduckgo.com/?q={query}",
            "alwaysPromptDownload": true
          }
        }
        """
      try legacy.data(using: .utf8)!.write(to: storeURL)

      let store = PreferencesStore(storeURL: storeURL)
      #expect(store.preferences.keyboardShortcuts == nil)
    }
  }
}
