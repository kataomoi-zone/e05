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

  @Test("bar height is 36pt to read as a discrete floating pill")
  func heightIsPill() {
    #expect(FindBarView.barHeight == 36)
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

  @Test("setMatchPosition with nil sides clears the label")
  func setMatchPositionNilClears() {
    let bar = FindBarView(frame: .zero)
    bar.setMatchPosition(current: 3, total: 12)
    bar.setMatchPosition(current: nil, total: nil)
    #expect(bar.matchCountText == "")
  }

  @Test("setMatchPosition(0, 0) shows the no-match indicator")
  func setMatchPositionZeroShowsEmpty() {
    let bar = FindBarView(frame: .zero)
    bar.setMatchPosition(current: 0, total: 0)
    #expect(bar.matchCountText == "0 / 0")
  }

  @Test("setMatchPosition renders Brave-style current / total")
  func setMatchPositionRendersCurrentOverTotal() {
    let bar = FindBarView(frame: .zero)
    bar.setMatchPosition(current: 3, total: 12)
    #expect(bar.matchCountText == "3 / 12")
    bar.setMatchPosition(current: 1, total: 1)
    #expect(bar.matchCountText == "1 / 1")
  }

  @Test("setMatchPosition retains the last current when JS returns zero")
  func setMatchPositionRetainsLastKnown() {
    let bar = FindBarView(frame: .zero)
    bar.setMatchPosition(current: 5, total: 12)
    #expect(bar.matchCountText == "5 / 12")
    // Subsequent query can't locate the selection (landed in a
    // cross-origin iframe) and reports current=0 with the same
    // total — the label should stay on the previously-known hit.
    bar.setMatchPosition(current: 0, total: 12)
    #expect(bar.matchCountText == "5 / 12")
  }

  @Test("setMatchPosition drops the retained current when total becomes zero")
  func setMatchPositionResetsOnZeroTotal() {
    let bar = FindBarView(frame: .zero)
    bar.setMatchPosition(current: 5, total: 12)
    bar.setMatchPosition(current: 0, total: 0)
    #expect(bar.matchCountText == "0 / 0")
    // Further zero queries must not resurrect the previous value.
    bar.setMatchPosition(current: 0, total: 0)
    #expect(bar.matchCountText == "0 / 0")
  }
}
