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

    @Test("retired special-pane addresses round-trip intact for later fallback")
    func retiredAddressesRoundTrip() throws {
        // Old session files may still reference addresses whose panes
        // were retired in favour of the sidebar. The JSON layer must
        // carry them through unchanged so `PaneModel.init(.unknown)`
        // can apply the blank-browser fallback at load time.
        let addresses = ["e05://history", "e05://bookmarks", "e05://downloads"]
        let session = SessionState(
            workspaces: [
                SessionState.WorkspaceState(
                    columns: addresses.map { address in
                        SessionState.ColumnState(
                            panes: [SessionState.PaneState(address: address)],
                            focusedPaneIndex: 0,
                            width: 640,
                            heightRatios: []
                        )
                    },
                    focusedColumnIndex: 0,
                    scrollX: 0
                ),
            ],
            focusedWorkspaceIndex: 0,
            urlBarVisible: false
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        let panes = decoded.workspaces[0].columns.map(\.panes[0])
        #expect(panes.map(\.address) == addresses)
        // Sanity-check the address string still parses into a
        // `.unknown`-kind PaneAddress so the loader's fallback path
        // keeps applying.
        for pane in panes {
            let addr = PaneAddress(pane.address)
            #expect(addr?.kind == .unknown)
        }
    }

    @Test("sidebarPinned round-trips for both true and false")
    func sidebarPinnedRoundTrip() throws {
        for pinned in [true, false] {
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
                urlBarVisible: false,
                sidebarPinned: pinned
            )

            let data = try JSONEncoder().encode(session)
            let decoded = try JSONDecoder().decode(SessionState.self, from: data)

            #expect(decoded.sidebarPinned == pinned)
        }
    }
}
