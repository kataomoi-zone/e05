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
                SessionState.PaneState(address: "https://example.com")
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
            )
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
            )
          ],
          focusedColumnIndex: 0,
          scrollX: 0
        )
      ],
      focusedWorkspaceIndex: 0
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
        )
      ],
      focusedWorkspaceIndex: 0
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

  @Test("pane title round-trips and is omitted when unset")
  func paneTitleRoundTrip() throws {
    let session = SessionState(
      workspaces: [
        SessionState.WorkspaceState(
          columns: [
            SessionState.ColumnState(
              panes: [
                SessionState.PaneState(
                  address: "https://example.com",
                  title: "Example Domain"
                ),
                SessionState.PaneState(address: "e05://terminal"),
              ],
              focusedPaneIndex: 0,
              width: 640,
              heightRatios: [1]
            )
          ],
          focusedColumnIndex: 0,
          scrollX: 0
        )
      ],
      focusedWorkspaceIndex: 0
    )

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(SessionState.self, from: data)
    let panes = decoded.workspaces[0].columns[0].panes

    #expect(panes[0].title == "Example Domain")
    #expect(panes[1].title == nil)

    // Confirm the JSON payload itself omits the field when nil so
    // terminal-only sessions don't grow a dead key.
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("\"title\":null"))
  }

  @Test("pane title round-trips as nil when constructed without a title")
  func paneTitleRoundTripAsNil() throws {
    // Verifies that the auto-synthesised `decodeIfPresent` path on
    // `PaneState.title` keeps Optional semantics: a value-side `nil`
    // is encoded as an absent key by JSONEncoder, and that absent
    // key decodes back to `nil`. Going through encode → decode (vs
    // a hand-written legacy JSON fixture) means future non-Optional
    // additions to ColumnState / WorkspaceState don't break the
    // test setup.
    let session = makeSession(paneTitle: nil)
    let decoded = try roundTrip(session)
    #expect(decoded.workspaces[0].columns[0].panes[0].title == nil)
  }

  @Test("terminal working directory round-trips and is omitted when unset")
  func terminalWorkingDirectoryRoundTrip() throws {
    // Non-ASCII path stresses byte-exact UTF-8 fidelity through the
    // JSON round-trip — a real cwd can contain any filename byte.
    let cwd = "/Users/someone/プロジェクト/作業"
    let session = SessionState(
      workspaces: [
        SessionState.WorkspaceState(
          columns: [
            SessionState.ColumnState(
              panes: [
                SessionState.PaneState(
                  address: "e05://terminal",
                  terminalWorkingDirectory: cwd
                ),
                SessionState.PaneState(address: "e05://terminal"),
              ],
              focusedPaneIndex: 0,
              width: 640,
              heightRatios: [1]
            )
          ],
          focusedColumnIndex: 0,
          scrollX: 0
        )
      ],
      focusedWorkspaceIndex: 0
    )

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(SessionState.self, from: data)
    let panes = decoded.workspaces[0].columns[0].panes

    #expect(panes[0].terminalWorkingDirectory == cwd)
    #expect(panes[1].terminalWorkingDirectory == nil)

    // A pane that never reported a directory must not grow a dead key.
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(!json.contains("\"terminalWorkingDirectory\":null"))
  }

  @Test("finder addresses round-trip through session JSON intact")
  func finderAddressesRoundTrip() throws {
    // Covers the full save/load contract for `e05://finder` panes:
    //
    // 1. Plain ASCII paths must survive JSON encode/decode byte-for-byte.
    // 2. Non-ASCII paths (Japanese, etc.) must survive the percent-encoded
    //    form that `PaneAddress.finder(path:)` produces, and still decode
    //    back into the original path via `PaneAddress(string).currentPath`.
    // 3. Paths containing spaces encode safely (URLComponents percent-
    //    encodes them) and decode back to the original spaced form.
    // 4. The root path `/` round-trips without being dropped by URL parsing.
    // 5. The bare `e05://finder` URL — which `PaneModel.init(address:)`
    //    treats as the trigger to substitute the user's home directory —
    //    round-trips as-is. A refactor that starts emitting `e05://finder/`
    //    or dropping the bare form would break the home-fallback path
    //    silently; this pins the contract at the session.json layer.
    let paths = [
      "/Users/kawarimidoll",
      "/Users/kawarimidoll/日本語フォルダ",
      "/Users/kawarimidoll/My Documents",
      "/",
    ]
    let expectedPathAddresses = paths.map { PaneAddress.finder(path: $0).description }
    let bareFinder = "e05://finder"
    let addresses = expectedPathAddresses + [bareFinder]

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
        )
      ],
      focusedWorkspaceIndex: 0
    )

    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(SessionState.self, from: data)
    let decodedAddresses = decoded.workspaces[0].columns.map(\.panes[0].address)

    #expect(decodedAddresses == addresses)

    // Each decoded address string must re-parse into a `.finder`-kind
    // PaneAddress so `restoreSession` routes it to FinderPaneView rather
    // than falling through to the blank-browser branch in
    // `PaneModel.init(address:)`.
    for addressString in decodedAddresses {
      #expect(PaneAddress(addressString)?.kind == .finder)
    }

    // Spot-check that path decoding survives the percent-encoding round
    // trip for each non-bare entry — the plain ASCII, Japanese, spaced,
    // and root variants all reach `currentPath` in their original form.
    for (path, addressString) in zip(paths, decodedAddresses) {
      let parsed = try #require(PaneAddress(addressString))
      #expect(parsed.currentPath == path)
    }

    // The bare entry resolves to an empty `currentPath`, which is the
    // signal `PaneModel.init(address:)` reads to substitute
    // `FileManager.default.homeDirectoryForCurrentUser`.
    let bare = try #require(PaneAddress(bareFinder))
    #expect(bare.currentPath.isEmpty)
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
              )
            ],
            focusedColumnIndex: 0,
            scrollX: 0
          )
        ],
        focusedWorkspaceIndex: 0,
        sidebarPinned: pinned
      )

      let data = try JSONEncoder().encode(session)
      let decoded = try JSONDecoder().decode(SessionState.self, from: data)

      #expect(decoded.sidebarPinned == pinned)
    }
  }

  @Test("collapsedIds round-trips and is omitted when nil")
  func collapsedIdsRoundTrip() throws {
    let base = SessionState.WorkspaceState(
      columns: [
        SessionState.ColumnState(
          panes: [SessionState.PaneState(address: "e05://terminal")],
          focusedPaneIndex: 0,
          width: 640,
          heightRatios: []
        )
      ],
      focusedColumnIndex: 0,
      scrollX: 0
    )

    // Encoding `nil` must omit the key from the JSON payload — a
    // session that never collapses anything shouldn't grow a dead
    // field over its lifetime.
    let empty = SessionState(
      workspaces: [base], focusedWorkspaceIndex: 0,
      collapsedIds: nil
    )
    let emptyData = try JSONEncoder().encode(empty)
    let emptyJSON = try #require(String(data: emptyData, encoding: .utf8))
    #expect(!emptyJSON.contains("collapsedIds"))
    let emptyDecoded = try JSONDecoder().decode(SessionState.self, from: emptyData)
    #expect(emptyDecoded.collapsedIds == nil)

    // Non-empty round-trip preserves order so the restore path can
    // rehydrate the in-memory set with one filter pass against the
    // live workspace / column ids.
    let ids = [ULID().string, ULID().string, ULID().string]
    let populated = SessionState(
      workspaces: [base], focusedWorkspaceIndex: 0,
      collapsedIds: ids
    )
    let data = try JSONEncoder().encode(populated)
    let decoded = try JSONDecoder().decode(SessionState.self, from: data)
    #expect(decoded.collapsedIds == ids)
  }

  @Test("workspace and column ids round-trip through encode/decode")
  func idRoundTrip() throws {
    let wsId = ULID().string
    let colId = ULID().string
    let session = SessionState(
      workspaces: [
        SessionState.WorkspaceState(
          id: wsId,
          columns: [
            SessionState.ColumnState(
              id: colId,
              panes: [SessionState.PaneState(address: "e05://terminal")],
              focusedPaneIndex: 0,
              width: 640,
              heightRatios: []
            )
          ],
          focusedColumnIndex: 0,
          scrollX: 0
        )
      ],
      focusedWorkspaceIndex: 0
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(SessionState.self, from: data)
    #expect(decoded.workspaces.first?.id == wsId)
    #expect(decoded.workspaces.first?.columns.first?.id == colId)
  }

  @Test("workspace / column ids round-trip as nil when omitted")
  func idsRoundTripAsNil() throws {
    // The restore path generates fresh ULIDs whenever id is nil, so
    // the Codable surface must keep the field Optional on both
    // sides of a round-trip.
    let session = makeSession(workspaceId: nil, columnId: nil)
    let decoded = try roundTrip(session)
    #expect(decoded.workspaces.first?.id == nil)
    #expect(decoded.workspaces.first?.columns.first?.id == nil)
  }

  @Test("collapsedIds round-trips as nil when not provided")
  func collapsedIdsRoundTripAsNil() throws {
    let session = makeSession(collapsedIds: nil)
    let decoded = try roundTrip(session)
    #expect(decoded.collapsedIds == nil)
  }

  // MARK: - Helpers

  /// Schema-complete `SessionState` factory whose Optional fields can
  /// be flipped individually to verify the auto-synthesised Codable
  /// surface. Defaults populate every Optional with a non-nil value
  /// so a per-field nil really is the variable under test rather
  /// than a coincidence of the surrounding fixture.
  private func makeSession(
    workspaceId: String? = "01JTESTWORKSPACE0000000001",
    columnId: String? = "01JTESTCOLUMN00000000000001",
    paneTitle: String? = "Example Domain",
    collapsedIds: [String]? = ["01JTESTCOLLAPSED0000000001"]
  ) -> SessionState {
    var paneState = SessionState.PaneState(address: "https://example.com")
    paneState.title = paneTitle
    return SessionState(
      workspaces: [
        SessionState.WorkspaceState(
          id: workspaceId,
          columns: [
            SessionState.ColumnState(
              id: columnId,
              panes: [paneState],
              focusedPaneIndex: 0,
              width: 640,
              heightRatios: []
            )
          ],
          focusedColumnIndex: 0,
          scrollX: 0
        )
      ],
      focusedWorkspaceIndex: 0,
      collapsedIds: collapsedIds
    )
  }

  /// Encode → decode through the production Codable path. Failures
  /// surface as test errors instead of being swallowed.
  private func roundTrip(_ session: SessionState) throws -> SessionState {
    let data = try JSONEncoder().encode(session)
    return try JSONDecoder().decode(SessionState.self, from: data)
  }
}
