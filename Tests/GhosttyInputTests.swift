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

  // MARK: - Scroll

  /// The scroll mods field is not the keyboard mods field, and the two
  /// overlap where it hurts: a lone Shift is 1 as a keyboard mod, and 1
  /// here means "these deltas are precise". Sending keyboard state on
  /// this call made every unmodified scroll claim to be a wheel tick,
  /// which libghostty scales by the cell height — a screenful per flick
  /// on a trackpad — while Shift made a wheel's ticks claim to be
  /// pixels, which took dozens of notches to move a row.
  @Test("scroll mods carry precision and momentum, not keyboard state")
  func scrollModsAreNotKeyboardMods() {
    #expect(GhosttyInput.scrollInput(deltaX: 0, deltaY: 1, precise: false).mods == 0)
    // Bit 0, which a keyboard Shift would also set.
    #expect(GhosttyInput.scrollInput(deltaX: 0, deltaY: 1, precise: true).mods == 1)
    // Bits 1-3, which the other keyboard modifiers would also set.
    #expect(
      GhosttyInput.scrollInput(
        deltaX: 0, deltaY: 1, precise: false, momentum: GHOSTTY_MOUSE_MOMENTUM_CHANGED
      ).mods == Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1)
    #expect(
      GhosttyInput.scrollInput(
        deltaX: 0, deltaY: 1, precise: true, momentum: GHOSTTY_MOUSE_MOMENTUM_ENDED
      ).mods == 1 | Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue) << 1)
  }

  /// Doubling precise deltas is ghostty's own feel adjustment; a wheel's
  /// ticks are counts and must not be touched, or every notch would move
  /// two rows.
  @Test("precise deltas are doubled and tick deltas are not")
  func scrollScalesPreciseDeltasOnly() {
    let precise = GhosttyInput.scrollInput(deltaX: -3, deltaY: 12.5, precise: true)
    #expect(precise.deltaX == -6)
    #expect(precise.deltaY == 25)

    let ticks = GhosttyInput.scrollInput(deltaX: -1, deltaY: 3, precise: false)
    #expect(ticks.deltaX == -1)
    #expect(ticks.deltaY == 3)
  }

  @Test("momentum phases map to libghostty's own values")
  func scrollMomentumMapping() {
    #expect(GhosttyInput.scrollMomentum(.began) == GHOSTTY_MOUSE_MOMENTUM_BEGAN)
    #expect(GhosttyInput.scrollMomentum(.stationary) == GHOSTTY_MOUSE_MOMENTUM_STATIONARY)
    #expect(GhosttyInput.scrollMomentum(.changed) == GHOSTTY_MOUSE_MOMENTUM_CHANGED)
    #expect(GhosttyInput.scrollMomentum(.ended) == GHOSTTY_MOUSE_MOMENTUM_ENDED)
    #expect(GhosttyInput.scrollMomentum(.cancelled) == GHOSTTY_MOUSE_MOMENTUM_CANCELLED)
    #expect(GhosttyInput.scrollMomentum(.mayBegin) == GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN)
    // No phase, and — since this is an OptionSet and the cases match by
    // equality — any combination of phases, report as none. That is what
    // ghostty's apprt does with the same switch. Nothing reads momentum
    // at the pinned libghostty, so a wrong value here would sit quiet
    // until the day something does.
    #expect(GhosttyInput.scrollMomentum([]) == GHOSTTY_MOUSE_MOMENTUM_NONE)
    #expect(GhosttyInput.scrollMomentum([.began, .ended]) == GHOSTTY_MOUSE_MOMENTUM_NONE)
  }

  /// The bug this all came from was in none of the above: the call site
  /// handed libghostty the keyboard modifiers instead, and every case
  /// that stops at the pure function would have passed right through it.
  /// So one case starts where the defect was, at an AppKit event.
  @Test("an AppKit scroll event is read for precision, deltas and momentum")
  func scrollInputReadsTheEvent() throws {
    // Continuous units are what a trackpad or a Magic Mouse sends.
    let precise = try #require(makeScrollEvent(deltaY: 30, deltaX: -10, continuous: true))
    let preciseInput = GhosttyInput.scrollInput(from: precise)
    #expect(preciseInput.mods & 1 == 1)
    #expect(preciseInput.deltaY == 60)
    #expect(preciseInput.deltaX == -20)

    // A notched wheel reports lines, and must not claim precision — the
    // scale libghostty puts on a tick is a different one entirely.
    let wheel = try #require(makeScrollEvent(deltaY: 1, deltaX: 0, continuous: false))
    let wheelInput = GhosttyInput.scrollInput(from: wheel)
    #expect(wheelInput.mods & 1 == 0)
    #expect(wheelInput.deltaY == 1)

    // Momentum rides in the same field, above the precision bit.
    let coasting = try #require(
      makeScrollEvent(deltaY: 4, deltaX: 0, continuous: true, momentumPhase: 2))
    let coastingInput = GhosttyInput.scrollInput(from: coasting)
    #expect(
      coastingInput.mods == 1 | Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1)
  }

  // MARK: - Composing

  /// An input method that takes a control key for itself and returns
  /// nothing leaves a key event behind carrying the control character.
  /// The terminal is told a composition is open and does not encode it,
  /// but bindings are matched before that flag is looked at, so the key
  /// has to stop here.
  @Test("a bare control character during composition belongs to the input method")
  func composingControlInputIsSuppressed() {
    // ctrl+h to cancel a composition, Esc to abandon one.
    #expect(GhosttyInput.suppressesComposingControlInput("\u{08}", composing: true))
    #expect(GhosttyInput.suppressesComposingControlInput("\u{1B}", composing: true))
  }

  /// The half that must not over-reach: with no composition open, ctrl+k
  /// is the shell's kill-line and has to arrive.
  @Test("control characters outside a composition still reach the terminal")
  func controlInputPassesWhenNotComposing() {
    #expect(!GhosttyInput.suppressesComposingControlInput("\u{0B}", composing: false))
    #expect(!GhosttyInput.suppressesComposingControlInput("\u{08}", composing: false))
  }

  @Test("real text during composition is not mistaken for a command")
  func composingTextIsNotSuppressed() {
    // What the input method commits, which is the point of composing.
    #expect(!GhosttyInput.suppressesComposingControlInput("カタカナ", composing: true))
    #expect(!GhosttyInput.suppressesComposingControlInput("a", composing: true))
    // Only a lone control character is the input method's. A longer
    // string that merely starts with one is text.
    #expect(!GhosttyInput.suppressesComposingControlInput("\u{0B}あ", composing: true))
    #expect(!GhosttyInput.suppressesComposingControlInput("", composing: true))
    #expect(!GhosttyInput.suppressesComposingControlInput(nil, composing: true))
    // Space is the boundary and sits outside: it is how a Japanese input
    // method asks for the next conversion candidate, and it is text.
    #expect(!GhosttyInput.suppressesComposingControlInput(" ", composing: true))
  }

  /// After an input method commits, the key that triggered the commit is
  /// the input method's instruction and stays out of the terminal —
  /// except for arrows, where moving off the composition is also a
  /// request to move the cursor.
  @Test("only arrows replay after a committed composition")
  func replayAfterCommittedPreedit() {
    // ctrl+k, Return, Space: the instruction, not a cursor move.
    #expect(!GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x28, modifierFlags: .control))
    #expect(!GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x24, modifierFlags: []))
    #expect(!GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x31, modifierFlags: []))

    #expect(GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x7D, modifierFlags: []))
    #expect(GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x7C, modifierFlags: []))
    #expect(GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x7E, modifierFlags: []))

    // Plain left-arrow is the exception's exception: AppKit has already
    // put the caret where it belongs, so replaying it would move twice.
    // Any of the four modifiers makes it a movement again, so all four
    // are pinned — one of them standing in for the set would pass a
    // check that only looked at shift.
    #expect(!GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x7B, modifierFlags: []))
    #expect(GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x7B, modifierFlags: .shift))
    #expect(GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x7B, modifierFlags: .control))
    #expect(GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x7B, modifierFlags: .option))
    #expect(GhosttyInput.replaysKeyAfterCommittedPreedit(keyCode: 0x7B, modifierFlags: .command))
  }

  // The branching in `keyDown` that consults these two rules is not
  // reachable from a test: it runs `interpretKeyEvents`, which needs a
  // live input context and a surface to send to. The rules are covered
  // here; which branch calls them was verified against a running pane.

  // MARK: - Helper

  /// A scroll event, built the only way AppKit allows one to be built:
  /// through CGEvent. `continuous` is what `hasPreciseScrollingDeltas`
  /// reads, and `momentumPhase` takes CGEvent's own numbering, where 2
  /// is a coasting scroll.
  private func makeScrollEvent(
    deltaY: Int32,
    deltaX: Int32,
    continuous: Bool,
    momentumPhase: Int64 = 0
  ) -> NSEvent? {
    guard
      let cgEvent = CGEvent(
        scrollWheelEvent2Source: nil,
        units: continuous ? .pixel : .line,
        wheelCount: 2,
        wheel1: deltaY,
        wheel2: deltaX,
        wheel3: 0)
    else { return nil }
    cgEvent.setIntegerValueField(
      .scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
    if momentumPhase != 0 {
      cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    }
    return NSEvent(cgEvent: cgEvent)
  }

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
