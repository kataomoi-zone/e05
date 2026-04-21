import AppKit
import GhosttyKit

/// Helpers for converting AppKit key events to ghostty input structures.
public enum GhosttyInput {
  /// Convert NSEvent.ModifierFlags to ghostty_input_mods_e.
  public static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = 0
    if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(rawValue: mods)
  }

  /// Build ghostty_input_key_s from an NSEvent.
  public static func keyEvent(
    from event: NSEvent,
    action: ghostty_input_action_e,
    translationMods: ghostty_input_mods_e? = nil
  ) -> ghostty_input_key_s {
    var key = ghostty_input_key_s()
    key.action = action
    // ghostty expects the raw macOS keyCode, NOT the ghostty_input_key_e enum value.
    // Ghostty performs its own internal mapping.
    key.keycode = UInt32(event.keyCode)
    key.mods = ghosttyMods(event.modifierFlags)
    key.composing = false
    key.text = nil

    // consumed_mods: all except control and command
    var consumed = event.modifierFlags
    consumed.remove(.control)
    consumed.remove(.command)
    key.consumed_mods = ghosttyMods(consumed)

    // unshifted_codepoint: only for key events (not flagsChanged)
    if event.type == .keyDown || event.type == .keyUp {
      let modsToApply = translationMods.map { NSEvent.ModifierFlags(rawValue: UInt($0.rawValue)) } ?? []
      if let chars = event.characters(byApplyingModifiers: modsToApply),
        let scalar = chars.unicodeScalars.first
      {
        key.unshifted_codepoint = scalar.value
      }
    }

    return key
  }

  /// Get printable characters from an NSEvent, handling control characters.
  public static func ghosttyCharacters(from event: NSEvent) -> String? {
    guard let characters = event.characters else { return nil }
    guard characters.count == 1,
      let scalar = characters.unicodeScalars.first
    else {
      return characters
    }

    // Private Use Area = function keys (F1-F20, arrows, etc.)
    if scalar.value >= 0xF700, scalar.value <= 0xF8FF {
      return nil
    }

    // Control characters: re-derive without control modifier
    // so ghostty can map the physical key correctly.
    // Note: the caller (sendKeyEvent) filters out codepoint < 0x20
    // so ghostty handles control character encoding itself.
    if scalar.value < 0x20 {
      var flags = event.modifierFlags
      flags.remove(.control)
      return event.characters(byApplyingModifiers: flags)
    }

    return characters
  }

  // Note: No keycode mapping table needed. ghostty_input_key_s.keycode
  // takes the raw macOS keyCode directly. Ghostty handles internal mapping.
}
