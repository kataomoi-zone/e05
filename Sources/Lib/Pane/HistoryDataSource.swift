import Foundation

/// `ListPaneDataSource` backed by `BrowsingHistory` — drives the
/// `e05://history` pane. Rows show title + URL + relative visit time,
/// deduplicated by URL (only the most recent visit per URL).
@MainActor
public final class HistoryDataSource: ListPaneDataSource {
    private let history: BrowsingHistory
    private let limit: Int

    /// Shared across all history panes — `RelativeDateTimeFormatter`
    /// allocation is expensive enough that a per-instance formatter
    /// shows up in time profiles when panes are opened repeatedly.
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    public var title: String { "History" }

    public init(history: BrowsingHistory, limit: Int = 500) {
        self.history = history
        self.limit = limit
    }

    public func load() -> [ListPaneRow] {
        history.mostRecent(limit: limit).map { entry in
            ListPaneRow(
                id: entry.id,
                title: entry.title,
                url: entry.url,
                subtitle: Self.formatter.localizedString(
                    for: entry.visitedAt, relativeTo: Date()
                )
            )
        }
    }

    public func delete(id: Int64) {
        history.delete(id: id)
    }
}
