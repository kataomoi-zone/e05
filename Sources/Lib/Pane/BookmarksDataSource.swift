import Foundation

/// `ListPaneDataSource` backed by `Bookmarks` — drives the
/// `e05://bookmarks` pane. Rows show title + URL + "Added <date>".
@MainActor
public final class BookmarksDataSource: ListPaneDataSource {
    private let bookmarks: Bookmarks

    /// Shared across all bookmark panes — `DateFormatter` allocation
    /// is expensive enough to benefit from sharing at the type level.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    public var title: String { "Bookmarks" }

    public init(bookmarks: Bookmarks) {
        self.bookmarks = bookmarks
    }

    public func load() -> [ListPaneRow] {
        bookmarks.all().map { entry in
            ListPaneRow(
                id: entry.id,
                title: entry.title,
                url: entry.url,
                subtitle: "Added \(Self.formatter.string(from: entry.createdAt))"
            )
        }
    }

    public func delete(id: Int64) {
        bookmarks.remove(id: id)
    }
}
