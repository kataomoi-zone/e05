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

  /// `windowNumber: 0` leaves the event windowless, which is what keeps
  /// `locationInWindow` the raw value passed here.
  private func mouse(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, clicks: Int = 1) -> NSEvent
  {
    NSEvent.mouseEvent(
      with: type,
      location: NSPoint(x: x, y: y),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: clicks,
      pressure: 1
    )!
  }

  private func activeHandle(_ orientation: PaneResizeHandle.Orientation) -> PaneResizeHandle {
    let handle = PaneResizeHandle(orientation: orientation)
    handle.isActive = true
    return handle
  }

  /// Every click past the first answers, not just the second: AppKit keeps
  /// counting a run of quick clicks, so a triple click would otherwise
  /// start a drag on a gesture meant as another double click and the
  /// tremor before mouseUp would undo what the double click just did.
  @Test("a double click runs the double-click action instead of starting a drag")
  func doubleClickSkipsDrag() {
    for clicks in [2, 3, 4] {
      let handle = activeHandle(.vertical)
      var equalized = 0
      var dragged: [CGFloat] = []
      handle.onDoubleClick = { equalized += 1 }
      handle.onDrag = { dragged.append($0) }

      handle.mouseDown(with: mouse(.leftMouseDown, x: 0, y: 100, clicks: clicks))
      handle.mouseDragged(with: mouse(.leftMouseDragged, x: 0, y: 140))

      #expect(equalized == 1, "click \(clicks) did not reach the double-click action")
      #expect(dragged.isEmpty, "click \(clicks) started a drag")
    }
  }

  /// AppKit reports the second press of any quick pair as `clickCount 2`,
  /// so a handle that swallowed those unconditionally would make a resize
  /// starting on the heels of an earlier click do nothing at all. Every
  /// handle the app builds now carries a double-click action, which is
  /// what makes this the handle's own contract to keep rather than a case
  /// some call site happens to rely on.
  @Test("without a double-click action the second click still drags")
  func doubleClickFallsThroughToDrag() {
    let handle = activeHandle(.horizontal)
    var dragged: [CGFloat] = []
    handle.onDrag = { dragged.append($0) }

    handle.mouseDown(with: mouse(.leftMouseDown, x: 200, y: 0, clicks: 2))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 230, y: 0))

    #expect(dragged == [30])
  }

  @Test("a drag announces its start once, before the first delta")
  func dragBeginsBeforeFirstDelta() {
    let handle = activeHandle(.horizontal)
    var order: [String] = []
    handle.onDragBegan = { order.append("began") }
    handle.onDrag = { order.append("drag \($0)") }

    handle.mouseDown(with: mouse(.leftMouseDown, x: 100, y: 0))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 110, y: 0))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 125, y: 0))

    #expect(order == ["began", "drag 10.0", "drag 15.0"])
  }

  @Test("an inactive handle answers neither gesture")
  func inactiveHandleIsInert() {
    let handle = PaneResizeHandle(orientation: .vertical)
    var fired = 0
    handle.onDoubleClick = { fired += 1 }
    handle.onDragBegan = { fired += 1 }
    handle.onDrag = { _ in fired += 1 }

    handle.mouseDown(with: mouse(.leftMouseDown, x: 0, y: 100, clicks: 2))
    handle.mouseDown(with: mouse(.leftMouseDown, x: 0, y: 100))
    handle.mouseDragged(with: mouse(.leftMouseDragged, x: 0, y: 140))

    #expect(fired == 0)
  }

  @Test("a vertical handle measures the drag on the y axis, a horizontal one on x")
  func dragAxisFollowsOrientation() {
    let vertical = activeHandle(.vertical)
    var verticalDeltas: [CGFloat] = []
    vertical.onDrag = { verticalDeltas.append($0) }
    vertical.mouseDown(with: mouse(.leftMouseDown, x: 10, y: 100))
    vertical.mouseDragged(with: mouse(.leftMouseDragged, x: 90, y: 80))

    let horizontal = activeHandle(.horizontal)
    var horizontalDeltas: [CGFloat] = []
    horizontal.onDrag = { horizontalDeltas.append($0) }
    horizontal.mouseDown(with: mouse(.leftMouseDown, x: 10, y: 100))
    horizontal.mouseDragged(with: mouse(.leftMouseDragged, x: 90, y: 80))

    #expect(verticalDeltas == [-20])
    #expect(horizontalDeltas == [80])
  }
}
