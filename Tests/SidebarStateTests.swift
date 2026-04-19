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

    @Test("pushesContent is true only for .pinnedOpen")
    func pushesContent() {
        #expect(SidebarState.hidden.pushesContent == false)
        // Hover peek overlays the content — crucial so the workspace
        // doesn't reshuffle columns on a transient reveal.
        #expect(SidebarState.hoverPeek.pushesContent == false)
        #expect(SidebarState.pinnedOpen.pushesContent == true)
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
