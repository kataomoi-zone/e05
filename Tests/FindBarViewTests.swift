import AppKit
import Testing

@testable import E05Lib

@Suite("FindBarView")
@MainActor
struct FindBarViewTests {
  @Test("initial search text is empty")
  func initialSearchTextIsEmpty() {
    let bar = FindBarView(frame: .zero)
    #expect(bar.searchText == "")
  }

  @Test("search text setter updates the displayed value")
  func searchTextSetterUpdates() {
    let bar = FindBarView(frame: .zero)
    bar.searchText = "needle"
    #expect(bar.searchText == "needle")
  }

  @Test("bar height matches PaneURLBar so the two stack on one baseline")
  func heightMatchesURLBar() {
    #expect(FindBarView.barHeight == PaneURLBar.barHeight)
  }

  @Test("Return dispatches onNext via the text field delegate")
  func returnDispatchesNext() {
    let bar = FindBarView(frame: .zero)
    var fired = 0
    bar.onNext = { fired += 1 }
    let handled = bar.control(
      NSTextField(),
      textView: NSTextView(),
      doCommandBy: #selector(NSResponder.insertNewline(_:))
    )
    #expect(handled)
    #expect(fired == 1)
  }

  @Test("insertLineBreak dispatches onPrev as a fallback path")
  func insertLineBreakDispatchesPrev() {
    let bar = FindBarView(frame: .zero)
    var fired = 0
    bar.onPrev = { fired += 1 }
    let handled = bar.control(
      NSTextField(),
      textView: NSTextView(),
      doCommandBy: #selector(NSResponder.insertLineBreak(_:))
    )
    #expect(handled)
    #expect(fired == 1)
  }

  @Test("cancelOperation dispatches onClose")
  func cancelDispatchesClose() {
    let bar = FindBarView(frame: .zero)
    var fired = 0
    bar.onClose = { fired += 1 }
    let handled = bar.control(
      NSTextField(),
      textView: NSTextView(),
      doCommandBy: #selector(NSResponder.cancelOperation(_:))
    )
    #expect(handled)
    #expect(fired == 1)
  }

  @Test("unknown selector is not consumed")
  func unknownSelectorNotConsumed() {
    let bar = FindBarView(frame: .zero)
    let handled = bar.control(
      NSTextField(),
      textView: NSTextView(),
      doCommandBy: #selector(NSResponder.moveRight(_:))
    )
    #expect(!handled)
  }
}
