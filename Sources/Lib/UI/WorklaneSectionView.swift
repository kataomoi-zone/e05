import AppKit

/// Sidebar worklane section: flat vertical list of every workspace and
/// its panes across all workspaces. Column-level hierarchy is
/// intentionally not surfaced — the sidebar gives an overview; the
/// workspace scroll strip is the detail view.
///
/// Rebuild strategy (stage 2): blow away all `arrangedSubviews` and
/// rebuild from scratch on every `reload(...)`. With the current
/// invariants (≤ 5 workspaces × small pane counts) the cost is
/// negligible; diff-based reload is a stage 5 optimization candidate.
@MainActor
final class WorklaneSectionView: NSView {
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
        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
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
        let onWorkspaceClick: (Int) -> Void
        let onPaneClick: (ULID) -> Void
    }

    func reload(_ input: ReloadInput) {
        for v in stackView.arrangedSubviews.reversed() {
            stackView.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        for (wsIdx, ws) in input.workspaces.enumerated() {
            let isCurrentWs = wsIdx == input.focusedWorkspaceIndex
            let wsColor = input.accentColor(wsIdx)
            let header = WorkspaceHeaderRow(
                index: wsIdx,
                title: "Workspace \(wsIdx + 1)",
                accentColor: wsColor,
                isCurrent: isCurrentWs
            )
            header.onClick = { [onClick = input.onWorkspaceClick] in onClick(wsIdx) }
            stackView.addArrangedSubview(header)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
                header.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
            ])

            for column in ws.columns {
                for pane in column.panes {
                    let isCurrentPane = pane.id == input.focusedPaneId
                    let row = PaneRow(
                        paneId: pane.id,
                        title: input.paneTitle(pane),
                        accentColor: wsColor,
                        isCurrent: isCurrentPane
                    )
                    let capturedId = pane.id
                    row.onClick = { [onClick = input.onPaneClick] in onClick(capturedId) }
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
