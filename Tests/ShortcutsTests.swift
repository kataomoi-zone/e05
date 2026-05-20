import AppKit
import Foundation
import Testing

@testable import E05Lib

@Suite("ShortcutBinding")
struct ShortcutBindingTests {
  @Test("Codable round-trip preserves both fields")
  func codableRoundTrip() throws {
    let binding = ShortcutBinding(keyEquivalent: "k", modifierMask: NSEvent.ModifierFlags.command.rawValue)
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
      #expect(overrides["close_pane"]?.modifierMask
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
