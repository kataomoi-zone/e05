import Foundation
import Testing

@testable import E05Lib

@Suite("SessionState")
struct SessionStateTests {
    @Test("round-trip encode/decode preserves state across workspaces")
    func roundTrip() throws {
        let session = SessionState(
            workspaces: [
                SessionState.WorkspaceState(
                    columns: [
                        SessionState.ColumnState(
                            panes: [
                                SessionState.PaneState(address: "e05://terminal"),
                                SessionState.PaneState(address: "e05://terminal"),
                            ],
                            focusedPaneIndex: 1,
                            width: 640,
                            heightRatios: [1.5]
                        ),
                        SessionState.ColumnState(
                            panes: [
                                SessionState.PaneState(address: "https://example.com"),
                            ],
                            focusedPaneIndex: 0,
                            width: 800,
                            heightRatios: []
                        ),
                    ],
                    focusedColumnIndex: 0,
                    scrollX: 120
                ),
                SessionState.WorkspaceState(
                    columns: [
                        SessionState.ColumnState(
                            panes: [SessionState.PaneState(address: "e05://terminal")],
                            focusedPaneIndex: 0,
                            width: 500,
                            heightRatios: []
                        ),
                    ],
                    focusedColumnIndex: 0,
                    scrollX: 0
                ),
            ],
            focusedWorkspaceIndex: 1,
            urlBarVisible: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        #expect(decoded.workspaces.count == 2)
        #expect(decoded.focusedWorkspaceIndex == 1)
        #expect(decoded.urlBarVisible == true)

        let ws0 = decoded.workspaces[0]
        #expect(ws0.columns.count == 2)
        #expect(ws0.focusedColumnIndex == 0)
        #expect(ws0.scrollX == 120)
        #expect(ws0.columns[0].panes.count == 2)
        #expect(ws0.columns[0].panes[0].address == "e05://terminal")
        #expect(ws0.columns[0].focusedPaneIndex == 1)
        #expect(ws0.columns[0].width == 640)
        #expect(ws0.columns[0].heightRatios == [1.5])
        #expect(ws0.columns[1].panes[0].address == "https://example.com")
        #expect(ws0.columns[1].width == 800)
        #expect(ws0.columns[1].heightRatios.isEmpty)

        let ws1 = decoded.workspaces[1]
        #expect(ws1.columns.count == 1)
        #expect(ws1.scrollX == 0)
    }

    @Test("single workspace with single terminal column")
    func singleWorkspace() throws {
        let session = SessionState(
            workspaces: [
                SessionState.WorkspaceState(
                    columns: [
                        SessionState.ColumnState(
                            panes: [SessionState.PaneState(address: "e05://terminal")],
                            focusedPaneIndex: 0,
                            width: 640,
                            heightRatios: []
                        ),
                    ],
                    focusedColumnIndex: 0,
                    scrollX: 0
                ),
            ],
            focusedWorkspaceIndex: 0,
            urlBarVisible: false
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        #expect(decoded.workspaces.count == 1)
        #expect(decoded.focusedWorkspaceIndex == 0)
        #expect(decoded.urlBarVisible == false)
    }

    @Test("decode fails for invalid JSON")
    func decodeInvalid() {
        let invalidData = Data("not json".utf8)
        let result = try? JSONDecoder().decode(SessionState.self, from: invalidData)
        #expect(result == nil)
    }
}
