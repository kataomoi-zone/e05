import Foundation
import Testing

@testable import E05Lib

@Suite("Action")
struct ActionTests {
    @Test("keyLabel builds standard macOS modifier order")
    @MainActor func keyLabelModifierOrder() {
        let action = Action(
            id: "test",
            title: "Test",
            keyEquivalent: "h",
            modifierMask: [.option, .control],
            handler: {}
        )
        #expect(action.keyLabel == "⌃⌥H")
    }

    @Test("keyLabel is nil when keyEquivalent is nil")
    @MainActor func keyLabelNilWhenNoKey() {
        let action = Action(
            id: "test",
            title: "Test",
            handler: {}
        )
        #expect(action.keyLabel == nil)
    }

    @Test("keyLabel includes shift symbol")
    @MainActor func keyLabelWithShift() {
        let action = Action(
            id: "test",
            title: "Test",
            keyEquivalent: "t",
            modifierMask: [.command, .shift],
            handler: {}
        )
        #expect(action.keyLabel == "⇧⌘T")
    }

    @Test("keyLabel with command only")
    @MainActor func keyLabelCommandOnly() {
        let action = Action(
            id: "test",
            title: "Test",
            keyEquivalent: "w",
            handler: {}
        )
        #expect(action.keyLabel == "⌘W")
    }
}
