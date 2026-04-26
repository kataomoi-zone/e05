import Foundation
import Testing

@testable import E05Lib

@Suite("SidebarState")
struct SidebarStateTests {
  @Test("isRevealed is false only for .hidden")
  func isRevealed() {
    #expect(SidebarState.hidden.isRevealed == false)
    #expect(SidebarState.hoverPeek.isRevealed == true)
    #expect(SidebarState.pinnedOpen.isRevealed == true)
  }

  @Test("reservesLeadingScrollInset matches isRevealed")
  func reservesLeadingScrollInset() {
    #expect(SidebarState.hidden.reservesLeadingScrollInset == false)
    // Both revealed states inflate `contentInsets.left`. The hover-peek
    // path then compensates with a matching `bounds.origin.x` advance
    // to cancel the visual shift, but the inset itself is required so
    // AppKit's cursor / tracking dispatch treats the leading strip as
    // off-document.
    #expect(SidebarState.hoverPeek.reservesLeadingScrollInset == true)
    #expect(SidebarState.pinnedOpen.reservesLeadingScrollInset == true)
  }

  @Test("equality covers every case pair")
  func equality() {
    let all: [SidebarState] = [.hidden, .hoverPeek, .pinnedOpen]
    for (i, a) in all.enumerated() {
      for (j, b) in all.enumerated() {
        #expect((a == b) == (i == j))
      }
    }
  }
}
