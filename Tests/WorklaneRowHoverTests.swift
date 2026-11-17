import AppKit
import Testing

@testable import E05Lib

@Suite("Worklane row hover")
@MainActor
struct WorklaneRowHoverTests {
  /// A worklane too short for its rows, in a window that is never key.
  private func makeSection(window: NSWindow) -> WorklaneSectionView {
    let workspace = WorkspaceModel()
    workspace.columns = (0..<30).map { _ in
      ColumnModel(pane: PaneModel(address: .blankBrowser, ghosttyApp: nil))
    }
    let section = WorklaneSectionView()
    let host = window.contentView!
    host.addSubview(section)
    NSLayoutConstraint.activate([
      section.topAnchor.constraint(equalTo: host.topAnchor),
      section.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      section.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      section.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    section.reload(
      .init(
        workspaces: [workspace],
        focusedWorkspaceIndex: 0,
        focusedPaneId: nil,
        accentColor: { _ in .systemBlue },
        paneTitle: { _ in "pane" },
        paneIcon: { _ in nil },
        paneAudioState: { _ in (false, false, false) },
        paneIsSuspended: { _ in false },
        paneIsLoading: { _ in false },
        paneProgramStatus: { _ in nil },
        isCollapsed: { _ in false },
        onWorkspaceClick: { _ in },
        onPaneClick: { _ in },
        onWorkspaceClose: { _ in },
        onPaneClose: { _ in },
        onColumnClose: { _ in },
        onPaneAudioToggle: { _ in },
        onToggleCollapse: { _ in },
        onReorderWorkspaces: { _ in },
        onMovePaneToWorkspace: { _, _, _ in },
        onMoveColumnToWorkspace: { _, _, _ in },
        onMovePaneToColumn: { _, _, _ in },
        onCrossPrivateBoundaryAttempt: {},
        onAddStartPaneToWorkspace: { _ in },
        onAddBrowserPaneToWorkspace: { _ in },
        onAddTerminalPaneToWorkspace: { _ in },
        onAddFinderPaneToWorkspace: { _ in },
        onCreateWorkspace: {},
        onCreatePrivateWorkspace: {},
        paneActionsProvider: { [] },
        onPaneAction: { _, _ in },
        onColumnAction: { _, _ in },
        onWorkspaceAction: { _, _ in },
        onRenameWorkspace: { _, _ in }
      ))
    host.layoutSubtreeIfNeeded()
    return section
  }

  private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }

  private func cells(in section: WorklaneSectionView) -> [any WorklaneHoverableCell] {
    descendants(of: section).compactMap { $0 as? any WorklaneHoverableCell }
  }

  private func tinted(in section: WorklaneSectionView) -> [any WorklaneHoverableCell] {
    cells(in: section).filter { $0.layer?.backgroundColor != nil }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }

  @Test("scrolling takes the tint off every row it passed")
  func scrollClearsPassedRows() throws {
    let window = makeWindow()
    defer { window.close() }
    let section = makeSection(window: window)
    let rows = cells(in: section)
    #expect(rows.count > 1)
    for row in rows { row.setHovered(true) }

    let scrollView = try #require(descendants(of: section).compactMap { $0 as? NSScrollView }.first)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 26))

    #expect(tinted(in: section).isEmpty)
  }

  @Test("only the row under the pointer is tinted, and it follows the scroll")
  func onlyRowUnderPointerIsTinted() throws {
    let window = makeWindow()
    defer { window.close() }
    let section = makeSection(window: window)
    let scrollView = try #require(descendants(of: section).compactMap { $0 as? NSScrollView }.first)
    let pointer = NSPoint(x: 120, y: window.frame.height - 60)
    let rows = cells(in: section)
    for row in rows { row.setHovered(true) }

    section.syncRowHover(pointerInWindow: pointer)
    let first = try #require(tinted(in: section).first)
    #expect(tinted(in: section).count == 1)
    #expect(NSMouseInRect(first.convert(pointer, from: nil), first.bounds, first.isFlipped))

    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 52))
    section.syncRowHover(pointerInWindow: pointer)
    let second = try #require(tinted(in: section).first)
    #expect(tinted(in: section).count == 1)
    #expect(second !== first)
    #expect(NSMouseInRect(second.convert(pointer, from: nil), second.bounds, second.isFlipped))
  }

  @Test("a row realised past the list's edge is not tinted through the footer")
  func clippedRowIsNotTinted() throws {
    let window = makeWindow()
    defer { window.close() }
    let section = makeSection(window: window)
    let scrollView = try #require(descendants(of: section).compactMap { $0 as? NSScrollView }.first)
    // Half a row, so one row straddles the clip view's edge.
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 13))
    section.layoutSubtreeIfNeeded()
    let clipped = try #require(
      cells(in: section).first {
        !$0.visibleRect.isEmpty && $0.visibleRect.height < $0.bounds.height
      })
    // The straddling row's part beyond the edge, where the footer shows.
    let hiddenPart = [clipped.bounds.minY + 1, clipped.bounds.maxY - 1]
      .map { NSPoint(x: clipped.bounds.midX, y: $0) }
      .first { !NSMouseInRect($0, clipped.visibleRect, clipped.isFlipped) }
    let pointer = clipped.convert(try #require(hiddenPart), to: nil)

    section.syncRowHover(pointerInWindow: pointer)

    #expect(tinted(in: section).isEmpty)
  }
}
