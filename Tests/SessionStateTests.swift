import Foundation
import Testing

@testable import E05Lib

@Suite("SessionState")
struct SessionStateTests {
    @Test("round-trip encode/decode preserves state")
    func roundTrip() throws {
        let session = SessionState(
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
            urlBarVisible: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        #expect(decoded.columns.count == 2)
        #expect(decoded.focusedColumnIndex == 0)
        #expect(decoded.urlBarVisible == true)

        #expect(decoded.columns[0].panes.count == 2)
        #expect(decoded.columns[0].panes[0].address == "e05://terminal")
        #expect(decoded.columns[0].focusedPaneIndex == 1)
        #expect(decoded.columns[0].width == 640)
        #expect(decoded.columns[0].heightRatios == [1.5])

        #expect(decoded.columns[1].panes[0].address == "https://example.com")
        #expect(decoded.columns[1].width == 800)
        #expect(decoded.columns[1].heightRatios.isEmpty)
    }

    @Test("single terminal column")
    func singleColumn() throws {
        let session = SessionState(
            columns: [
                SessionState.ColumnState(
                    panes: [SessionState.PaneState(address: "e05://terminal")],
                    focusedPaneIndex: 0,
                    width: 640,
                    heightRatios: []
                ),
            ],
            focusedColumnIndex: 0,
            urlBarVisible: false
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)

        #expect(decoded.columns.count == 1)
        #expect(decoded.urlBarVisible == false)
    }

    @Test("load returns nil for missing file")
    func loadMissing() {
        // Ensure no stale session file interferes
        SessionState.delete()
        #expect(SessionState.load() == nil)
    }
}
