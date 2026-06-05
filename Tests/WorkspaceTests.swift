import AppKit
import Foundation
import Testing

@testable import E05Lib

@Suite("Workspace")
struct WorkspaceTests {
  @Test("WorkspaceModel default state is empty")
  @MainActor func defaultState() {
    let ws = WorkspaceModel()
    #expect(ws.columns.isEmpty)
    #expect(ws.focusedColumnIndex == 0)
    #expect(ws.scrollX == 0)
  }

  @Test("WorkspaceModel instances get unique ids")
  @MainActor func uniqueIds() {
    let a = WorkspaceModel()
    let b = WorkspaceModel()
    #expect(a.id != b.id)
  }

  @Test("displayName falls back to the positional label when unnamed")
  @MainActor func displayNameFallback() {
    let ws = WorkspaceModel()
    #expect(ws.name == nil)
    #expect(ws.displayName(at: 0) == "Workspace 1")
    #expect(ws.displayName(at: 4) == "Workspace 5")
  }

  @Test("displayName returns the trimmed custom name when set")
  @MainActor func displayNameCustom() {
    let ws = WorkspaceModel()
    ws.name = "  Email  "
    #expect(ws.displayName(at: 2) == "Email")
  }

  @Test("displayName treats whitespace-only names as unnamed")
  @MainActor func displayNameBlank() {
    let ws = WorkspaceModel()
    ws.name = "   "
    #expect(ws.displayName(at: 1) == "Workspace 2")
  }

  @Test("accentColor returns the palette in order for the first cycle")
  @MainActor func accentColorPalette() {
    let palette = PaneContainerViewController.accentColorPalette
    for (index, expected) in palette.enumerated() {
      #expect(PaneContainerViewController.accentColor(forWorkspaceAt: index) == expected)
    }
  }

  @Test("accentColor wraps around once positions exceed the palette length")
  @MainActor func accentColorWraps() {
    let palette = PaneContainerViewController.accentColorPalette
    let length = palette.count
    #expect(length > 0)
    // Position N + paletteLength resolves to the same color as N for
    // every N in the palette range, so workspaces beyond the
    // palette cycle through the same values instead of running out.
    for index in 0..<length {
      let base = PaneContainerViewController.accentColor(forWorkspaceAt: index)
      let wrapped = PaneContainerViewController.accentColor(forWorkspaceAt: index + length)
      #expect(base == wrapped)
    }
  }

  @Test("accentColor stays total for negative and over-large positions")
  @MainActor func accentColorFallback() {
    // The getter must always return a usable color so a transient
    // empty state (mid-remove) or a malformed persisted session
    // can't crash startup. Negative and far-out-of-range positions
    // both resolve to the first palette entry.
    let first = PaneContainerViewController.accentColorPalette.first!
    #expect(PaneContainerViewController.accentColor(forWorkspaceAt: -1) == first)
    #expect(
      PaneContainerViewController.accentColor(
        forWorkspaceAt: PaneContainerViewController.accentColorPalette.count
      ) == first
    )
  }
}
