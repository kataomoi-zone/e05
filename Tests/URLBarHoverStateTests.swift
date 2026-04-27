import Foundation
import Testing

@testable import E05Lib

@Suite("URLBarHoverState")
struct URLBarHoverStateTests {
  @Test("isRevealed is false only for .hidden")
  func isRevealed() {
    #expect(URLBarHoverState.hidden.isRevealed == false)
    #expect(URLBarHoverState.peek.isRevealed == true)
    #expect(URLBarHoverState.pinned.isRevealed == true)
  }

  @Test("isPinned is true only for .pinned")
  func isPinned() {
    #expect(URLBarHoverState.hidden.isPinned == false)
    #expect(URLBarHoverState.peek.isPinned == false)
    #expect(URLBarHoverState.pinned.isPinned == true)
  }

  @Test("equality covers every case pair")
  func equality() {
    let all: [URLBarHoverState] = [.hidden, .peek, .pinned]
    for (i, a) in all.enumerated() {
      for (j, b) in all.enumerated() {
        #expect((a == b) == (i == j))
      }
    }
  }
}
