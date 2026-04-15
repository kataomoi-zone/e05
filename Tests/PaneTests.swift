import AppKit
import Testing

@testable import E05Lib

@Suite("PaneWidthPreset")
struct PaneWidthPresetTests {
    @Test("columns equality")
    func columnsEquality() {
        #expect(PaneWidthPreset.columns(80) == .columns(80))
        #expect(PaneWidthPreset.columns(80) != .columns(120))
    }

    @Test("fraction equality")
    func fractionEquality() {
        #expect(PaneWidthPreset.fraction(0.5) == .fraction(0.5))
        #expect(PaneWidthPreset.fraction(0.5) != .fraction(0.333))
    }

    @Test("columns and fraction are not equal")
    func crossTypeInequality() {
        #expect(PaneWidthPreset.columns(80) != .fraction(0.5))
    }
}

@Suite("PaneHeaderView")
@MainActor
struct PaneHeaderViewTests {
    @Test("starts hidden")
    func startsHidden() {
        let header = PaneHeaderView()
        #expect(header.alphaValue == 0)
    }

    @Test("hideImmediately sets alpha to zero")
    func hideImmediately() {
        let header = PaneHeaderView()
        header.alphaValue = 1
        header.hideImmediately()
        #expect(header.alphaValue == 0)
    }

    @Test("currentTitle reflects show title")
    func currentTitle() {
        let header = PaneHeaderView()
        header.show(title: "test-title", autoHide: false)
        #expect(header.currentTitle == "test-title")
    }
}

@Suite("PaneResizeHandle")
@MainActor
struct PaneResizeHandleTests {
    @Test("starts inactive")
    func startsInactive() {
        let handle = PaneResizeHandle()
        #expect(handle.isActive == false)
    }

    @Test("can be activated")
    func canActivate() {
        let handle = PaneResizeHandle()
        handle.isActive = true
        #expect(handle.isActive == true)
    }

    @Test("width constraint is correct")
    func widthConstraint() {
        let handle = PaneResizeHandle()
        let constraints = PaneResizeHandle.makeConstraints(for: handle)
        #expect(constraints.count == 1)
        #expect(constraints[0].constant == 6) // handleWidth
    }
}
