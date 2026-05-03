import AppKit

/// Sidebar worklane section: flat vertical list of every workspace and
/// its panes across all workspaces. Column-level hierarchy is
/// intentionally not surfaced — the sidebar gives an overview; the
/// workspace scroll strip is the detail view.
///
/// Hosted inside an `NSScrollView` so the section height stays bounded
/// by its parent and content overflow scrolls vertically. Without the
/// scroller the stack's intrinsic height would push the sidebar past
/// the window bottom once enough workspaces accumulated.
///
/// Rebuild strategy: blow away all `arrangedSubviews` and rebuild from
/// scratch on every `reload(...)`. Workspace and pane counts in practice
/// stay small, so the cost is negligible; diff-based reload remains an
/// optimization candidate if the list ever grows large.

/// Clip view that uses top-down (flipped) coordinates so a documentView
/// shorter than the clip area anchors to the top edge. The stock
/// `NSClipView` reports `isFlipped == false`, which leaves a too-short
/// stack hugging the bottom — a cosmetic regression that surfaced as
/// soon as the worklane started living inside a scroll view.
@MainActor
private final class FlippedClipView: NSClipView {
  override var isFlipped: Bool { true }

  // Absorb mouse events so the empty area below the worklane's stack
  // doesn't pass through `NSGlassEffectView`'s transparent regions to
  // the workspace pane underneath. The bookmarks / history / downloads
  // sidebar modes use `NSTableView`, which absorbs empty-area clicks
  // built-in; the worklane uses `NSScrollView` + `NSStackView`, which
  // forwards `mouseDown` up the responder chain via the NSResponder
  // default — and somewhere in that path the click leaks through the
  // glass to the webview, letting the user select text or follow links
  // through the sidebar's empty space. Empty overrides stop the chain
  // here, matching the table-view behaviour the other modes inherit.
  //
  // `scrollWheel`, `magnify`, and `swipe` are intentionally not
  // overridden so the enclosing `NSScrollView`'s default panning
  // (vertical wheel scroll, trackpad two-finger scroll, momentum
  // scroll) keeps working — only primary-button click and drag are
  // absorbed.
  override func mouseDown(with _: NSEvent) {}
  override func mouseDragged(with _: NSEvent) {}
  override func mouseUp(with _: NSEvent) {}
}

@MainActor
final class WorklaneSectionView: NSView {
  private let scrollView = NSScrollView()
  private let stackView = NSStackView()

  init() {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    stackView.orientation = .vertical
    stackView.spacing = 2
    stackView.alignment = .leading
    stackView.distribution = .fill
    stackView.translatesAutoresizingMaskIntoConstraints = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.verticalScrollElasticity = .allowed
    scrollView.horizontalScrollElasticity = .none
    // Replace the default clip view with a flipped one so a short stack
    // sticks to the top of the visible region. Set the clip view *before*
    // assigning `documentView` — `NSScrollView.contentView=` re-parents
    // any existing documentView into the new clip view, but going in the
    // other order works equally well in practice.
    //
    // `NSScrollView.drawsBackground=false` is *not* propagated to a clip
    // view installed afterwards, so the new clip view keeps its default
    // `drawsBackground=true` and paints `controlBackgroundColor` over
    // the parent Liquid Glass — visible as an opaque dark slab in dark
    // mode. Disable it explicitly on the replacement.
    let clipView = FlippedClipView()
    clipView.drawsBackground = false
    scrollView.contentView = clipView
    scrollView.documentView = stackView
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // Pin stack width to the clip view so rows lay out flush across
      // the sidebar with no horizontal scrolling. Height is left
      // intrinsic — the stack grows downward and scrolls inside the
      // clip view once it exceeds the available height.
      stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
      stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
      stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
    ])
  }

  /// Input bundle for `reload(_:)`. All closures are expected to run
  /// on the main actor synchronously — `ReloadInput` is not Sendable
  /// and should not be stashed across actor hops. Future async usage
  /// would need closures marked `@Sendable` and `@MainActor` explicitly.
  struct ReloadInput {
    let workspaces: [WorkspaceModel]
    let focusedWorkspaceIndex: Int
    let focusedPaneId: ULID?
    let accentColor: (Int) -> NSColor
    let paneTitle: (PaneModel) -> String
    let paneIcon: (PaneModel) -> NSImage?
    let isWorkspaceCollapsed: (ULID) -> Bool
    let onWorkspaceClick: (Int) -> Void
    let onPaneClick: (ULID) -> Void
    let onWorkspaceClose: (Int) -> Void
    let onPaneClose: (ULID) -> Void
    let onWorkspaceToggleCollapse: (ULID) -> Void
  }

  func reload(_ input: ReloadInput) {
    for v in stackView.arrangedSubviews.reversed() {
      stackView.removeArrangedSubview(v)
      v.removeFromSuperview()
    }

    for (wsIdx, ws) in input.workspaces.enumerated() {
      let isCurrentWs = wsIdx == input.focusedWorkspaceIndex
      let wsColor = input.accentColor(wsIdx)
      let isCollapsed = input.isWorkspaceCollapsed(ws.id)
      let header = WorkspaceHeaderRow(
        index: wsIdx,
        title: "Workspace \(wsIdx + 1)",
        accentColor: wsColor,
        isCurrent: isCurrentWs,
        isCollapsed: isCollapsed,
        isPrivate: ws.isPrivate
      )
      header.onClick = { [onClick = input.onWorkspaceClick] in onClick(wsIdx) }
      header.onClose = { [onClose = input.onWorkspaceClose] in onClose(wsIdx) }
      let wsId = ws.id
      header.onToggleCollapse = {
        [onToggle = input.onWorkspaceToggleCollapse] in onToggle(wsId)
      }
      stackView.addArrangedSubview(header)
      NSLayoutConstraint.activate([
        header.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
        header.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
      ])

      if isCollapsed { continue }

      // The "would-be focused pane" of each non-current workspace —
      // surfaced in the sidebar so the user can see where focus will
      // land before they switch over. Always-nil for an empty
      // workspace; for the current workspace the same pane is
      // already covered by `focusedPaneId`, so the indent line and
      // the in-row border don't double-decorate.
      let ownFocusPaneId = ws.columns[safe: ws.focusedColumnIndex]?.focusedPane?.id
      for column in ws.columns {
        for pane in column.panes {
          let isCurrentPane = pane.id == input.focusedPaneId
          let isOwnFocus = !isCurrentPane && pane.id == ownFocusPaneId
          let row = PaneRow(
            paneId: pane.id,
            title: input.paneTitle(pane),
            icon: input.paneIcon(pane),
            accentColor: wsColor,
            isCurrent: isCurrentPane,
            isOwnWorkspaceFocus: isOwnFocus,
            isPrivate: ws.isPrivate
          )
          let capturedId = pane.id
          row.onClick = { [onClick = input.onPaneClick] in onClick(capturedId) }
          row.onClose = { [onClose = input.onPaneClose] in onClose(capturedId) }
          stackView.addArrangedSubview(row)
          NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
          ])
        }
      }
    }
  }
}
