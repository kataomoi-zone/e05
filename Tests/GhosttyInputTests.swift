import AppKit
import GhosttyKit
import Testing

@testable import E05Lib

@Suite("GhosttyInput")
struct GhosttyInputTests {
  @Test("keycode uses raw macOS keyCode, not ghostty enum value")
  func keycodeIsRawMacOSKeyCode() {
    // ESC = macOS keyCode 0x35
    let escEvent = makeKeyEvent(keyCode: 0x35, characters: "\u{1B}")
    let escKey = GhosttyInput.keyEvent(from: escEvent, action: GHOSTTY_ACTION_PRESS)
    #expect(escKey.keycode == 0x35)

    // Enter = macOS keyCode 0x24
    let enterEvent = makeKeyEvent(keyCode: 0x24, characters: "\r")
    let enterKey = GhosttyInput.keyEvent(from: enterEvent, action: GHOSTTY_ACTION_PRESS)
    #expect(enterKey.keycode == 0x24)

    // A = macOS keyCode 0x00
    let aEvent = makeKeyEvent(keyCode: 0x00, characters: "a")
    let aKey = GhosttyInput.keyEvent(from: aEvent, action: GHOSTTY_ACTION_PRESS)
    #expect(aKey.keycode == 0x00)
  }

  @Test("ghosttyMods converts modifier flags correctly")
  func modsConversion() {
    let shift = GhosttyInput.ghosttyMods(.shift)
    #expect(shift.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0)
    #expect(shift.rawValue & GHOSTTY_MODS_CTRL.rawValue == 0)

    let ctrlCmd = GhosttyInput.ghosttyMods([.control, .command])
    #expect(ctrlCmd.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0)
    #expect(ctrlCmd.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0)
    #expect(ctrlCmd.rawValue & GHOSTTY_MODS_SHIFT.rawValue == 0)
  }

  @Test("ghosttyCharacters returns nil for PUA function keys")
  func puaFunctionKeysReturnNil() {
    // F1 = PUA 0xF704
    let f1Event = makeKeyEvent(keyCode: 0x7A, characters: "\u{F704}")
    let chars = GhosttyInput.ghosttyCharacters(from: f1Event)
    #expect(chars == nil)
  }

  @Test("ghosttyCharacters returns printable characters as-is")
  func printableCharactersPassThrough() {
    let aEvent = makeKeyEvent(keyCode: 0x00, characters: "a")
    let chars = GhosttyInput.ghosttyCharacters(from: aEvent)
    #expect(chars == "a")
  }

  // MARK: - Helper

  private func makeKeyEvent(
    keyCode: UInt16,
    characters: String,
    modifiers: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    )!
  }
}
