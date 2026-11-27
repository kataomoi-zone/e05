import AppKit
import Testing

@testable import E05Lib

@Suite("StartPaneView")
@MainActor
struct StartPaneViewTests {
  private func keyDown(_ characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent {
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
      keyCode: 0x11
    )!
  }

  @Test("T opens a terminal with Caps Lock on")
  func capsLockIsNotAChord() {
    let view = StartPaneView()
    var opened = false
    view.onOpenTerminal = { opened = true }
    view.keyDown(with: keyDown("T", modifiers: .capsLock))
    #expect(opened)
  }

  @Test("a chord on T is left alone")
  func chordFallsThrough() {
    let view = StartPaneView()
    var opened = false
    view.onOpenTerminal = { opened = true }
    view.keyDown(with: keyDown("t", modifiers: .control))
    #expect(!opened)
  }
}
