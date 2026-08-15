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

  /// What a scroll event carries into libghostty: the deltas, and the
  /// scroll mods that say how to read them.
  public struct ScrollInput {
    public let deltaX: Double
    public let deltaY: Double
    public let mods: ghostty_input_scroll_mods_t
  }

  /// Translate an AppKit scroll event for `ghostty_surface_mouse_scroll`.
  public static func scrollInput(from event: NSEvent) -> ScrollInput {
    scrollInput(
      deltaX: event.scrollingDeltaX,
      deltaY: event.scrollingDeltaY,
      precise: event.hasPreciseScrollingDeltas,
      momentum: scrollMomentum(event.momentumPhase))
  }

  /// Translate one scroll event for `ghostty_surface_mouse_scroll`.
  ///
  /// `mods` here is `ghostty_input_scroll_mods_t`, which is **not** the
  /// keyboard `ghostty_input_mods_e`: bit 0 says the deltas are precise,
  /// bits 1-3 carry the momentum phase. The two enums overlap — a lone
  /// Shift is `1` as a keyboard mod, which reads as "precise" here — so
  /// putting one where the other belongs silently changes how libghostty
  /// reads every scroll. Keyboard state is not wanted on this call at
  /// all: libghostty tracks the modifiers it needs for scrolling from
  /// key and mouse events, which the view already sends.
  ///
  /// The flag decides which of two unrelated scales libghostty applies.
  /// Precise deltas are pixels, and it divides them by the cell height
  /// after `mouse-scroll-multiplier.precision`, 1 by default.
  /// Imprecise ones are wheel ticks, and it multiplies them by the cell
  /// height and by `mouse-scroll-multiplier.discrete`, 3 by default —
  /// then, on macOS only, rounds any tick smaller than one up to a whole
  /// one. Pixels sent unflagged therefore land as three rows apiece at
  /// the very least, however gently the surface was touched.
  ///
  /// The doubling of precise deltas matches ghostty's own apprt, where
  /// it is a deliberate feel adjustment.
  public static func scrollInput(
    deltaX: Double,
    deltaY: Double,
    precise: Bool,
    momentum: ghostty_input_mouse_momentum_e = GHOSTTY_MOUSE_MOMENTUM_NONE
  ) -> ScrollInput {
    let scale: Double = precise ? 2 : 1
    var mods: Int32 = precise ? 1 : 0
    mods |= Int32(momentum.rawValue) << 1
    return ScrollInput(
      deltaX: deltaX * scale,
      deltaY: deltaY * scale,
      mods: ghostty_input_scroll_mods_t(mods))
  }

  /// Momentum phase of a scroll event, in libghostty's terms. A phase
  /// this does not name — including the compound values an OptionSet can
  /// hold — reports as none, which is what ghostty's own apprt does.
  public static func scrollMomentum(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
    switch phase {
    case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
    case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
    case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
    case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
    case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
    case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
    default: GHOSTTY_MOUSE_MOMENTUM_NONE
    }
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
      let modsToApply =
        translationMods.map { NSEvent.ModifierFlags(rawValue: UInt($0.rawValue)) } ?? []
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
