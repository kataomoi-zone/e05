import Foundation
import Testing

@testable import E05Lib

@Suite("Workspace")
struct WorkspaceTests {
    @Test("nextAccentColorIndex starts at 1 when no workspaces exist")
    @MainActor func nextColorStartsAtOne() {
        #expect(PaneContainerViewController.nextAccentColorIndex(used: []) == 1)
    }

    @Test("nextAccentColorIndex skips used indices")
    @MainActor func nextColorSkipsUsed() {
        #expect(PaneContainerViewController.nextAccentColorIndex(used: [1]) == 2)
        #expect(PaneContainerViewController.nextAccentColorIndex(used: [1, 2]) == 3)
    }

    @Test("nextAccentColorIndex fills holes before extending")
    @MainActor func nextColorFillsHoles() {
        // Workspace 2 was deleted; creating a new one reuses color 2.
        #expect(PaneContainerViewController.nextAccentColorIndex(used: [1, 3]) == 2)
        #expect(PaneContainerViewController.nextAccentColorIndex(used: [1, 3, 4]) == 2)
        #expect(PaneContainerViewController.nextAccentColorIndex(used: [2, 3, 5]) == 1)
    }

    @Test("nextAccentColorIndex falls back to 1 at max")
    @MainActor func nextColorFallbackAtMax() {
        // Fallback branch — all slots exhausted. The caller is expected to
        // gate on canCreateWorkspace, so this value shouldn't surface in
        // practice, but the function must still return deterministically.
        let full: Set<Int> = [1, 2, 3, 4, 5]
        #expect(PaneContainerViewController.nextAccentColorIndex(used: full) == 1)
    }

    @Test("WorkspaceModel default state is empty")
    @MainActor func defaultState() {
        let ws = WorkspaceModel(accentColorIndex: 3)
        #expect(ws.accentColorIndex == 3)
        #expect(ws.columns.isEmpty)
        #expect(ws.focusedColumnIndex == 0)
    }

    @Test("WorkspaceModel instances get unique ids")
    @MainActor func uniqueIds() {
        let a = WorkspaceModel(accentColorIndex: 1)
        let b = WorkspaceModel(accentColorIndex: 1)
        #expect(a.id != b.id)
    }
}
