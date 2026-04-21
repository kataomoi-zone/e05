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

  @Test("accentColor maps positions to the palette in order")
  @MainActor func accentColorPalette() {
    #expect(PaneContainerViewController.accentColor(forWorkspaceAt: 0) == .systemBlue)
    #expect(PaneContainerViewController.accentColor(forWorkspaceAt: 1) == .systemGreen)
    #expect(PaneContainerViewController.accentColor(forWorkspaceAt: 2) == .systemOrange)
    #expect(PaneContainerViewController.accentColor(forWorkspaceAt: 3) == .systemPurple)
    #expect(PaneContainerViewController.accentColor(forWorkspaceAt: 4) == .systemRed)
  }

  @Test("accentColor falls back when position is out of range")
  @MainActor func accentColorFallback() {
    // Keep the getter total so a transient empty state (mid-remove)
    // or a malformed persisted session can't crash startup.
    #expect(PaneContainerViewController.accentColor(forWorkspaceAt: -1) == .systemBlue)
    #expect(PaneContainerViewController.accentColor(forWorkspaceAt: 5) == .systemBlue)
  }
}
