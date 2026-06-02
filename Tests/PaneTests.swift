import AppKit
import Testing

@testable import E05Lib

@Suite("PaneWidthPreset")
struct PaneWidthPresetTests {
  @Test("points equality")
  func pointsEquality() {
    #expect(PaneWidthPreset.points(80) == .points(80))
    #expect(PaneWidthPreset.points(80) != .points(120))
  }

  @Test("fraction equality")
  func fractionEquality() {
    #expect(PaneWidthPreset.fraction(0.5) == .fraction(0.5))
    #expect(PaneWidthPreset.fraction(0.5) != .fraction(0.333))
  }

  @Test("points and fraction are not equal")
  func crossTypeInequality() {
    #expect(PaneWidthPreset.points(80) != .fraction(0.5))
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
    let handle = PaneResizeHandle(orientation: .horizontal)
    #expect(handle.isActive == false)
  }

  @Test("can be activated")
  func canActivate() {
    let handle = PaneResizeHandle(orientation: .horizontal)
    handle.isActive = true
    #expect(handle.isActive == true)
  }

  @Test("horizontal handle has width constraint")
  func widthConstraint() {
    let handle = PaneResizeHandle(orientation: .horizontal)
    let constraints = PaneResizeHandle.makeConstraints(for: handle)
    #expect(constraints.count == 1)
    #expect(constraints[0].constant == 6)  // handleSize
  }

  @Test("vertical handle has height constraint")
  func heightConstraint() {
    let handle = PaneResizeHandle(orientation: .vertical)
    let constraints = PaneResizeHandle.makeConstraints(for: handle)
    #expect(constraints.count == 1)
    #expect(constraints[0].constant == 6)  // handleSize
  }
}
