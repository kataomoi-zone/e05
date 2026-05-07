import AppKit

/// A single filesystem entry rendered in the finder pane's table. All
/// expensive metadata is cached at construction so the table's data-source
/// callbacks stay O(1) per row during scroll.
///
/// The cached keys match what `URLResourceKey.effectiveIcon` and friends
/// expose to AppKit: they're what Finder itself consumes, so items render
/// with the same icon artwork the user sees when previewing the directory
/// in Finder — including package icons, alias glyphs, and custom icons set
/// via Get Info.
///
/// `Sendable` + nonisolated so the directory walk in
/// `FinderPaneView.enumerate(...)` can construct items off the main actor
/// and hand the resulting `[FileItem]` back through `MainActor.run`. All
/// stored properties are immutable value types or `Sendable` references,
/// so the conformance is safe.
public final class FileItem: Sendable {
  public let url: URL
  public let name: String
  public let isDirectory: Bool
  public let isPackage: Bool
  public let isHidden: Bool
  public let isSymbolicLink: Bool
  public let size: Int64
  public let dateModified: Date?
  public let kind: String

  /// Resource keys fetched per item at construction time. The icon
  /// key is **not** included here — `URLResourceKey.effectiveIconKey`
  /// is the most expensive resource to resolve (~tens of µs per file,
  /// accounting for roughly half of the per-entry cost in directory
  /// walks), so icons are fetched on demand by `FinderPaneView`'s
  /// visible-row cache instead of eagerly for every entry. A directory
  /// with thousands of files pays the icon cost only for the ~30 rows
  /// actually on screen.
  static let resourceKeys: Set<URLResourceKey> = [
    .isDirectoryKey, .isPackageKey, .isHiddenKey, .isSymbolicLinkKey,
    .fileSizeKey, .contentModificationDateKey,
    .localizedTypeDescriptionKey,
  ]

  public init(url: URL) {
    self.url = url
    self.name = url.lastPathComponent

    let values = try? url.resourceValues(forKeys: Self.resourceKeys)

    self.isDirectory = values?.isDirectory ?? false
    self.isPackage = values?.isPackage ?? false
    self.isHidden = values?.isHidden ?? false
    self.isSymbolicLink = values?.isSymbolicLink ?? false
    self.size = Int64(values?.fileSize ?? 0)
    self.dateModified = values?.contentModificationDate
    self.kind = values?.localizedTypeDescription ?? "—"
  }

  /// Construct a synthetic placeholder for an in-flight batch-op
  /// target that hasn't landed on disk yet (Compress / Paste /
  /// Duplicate output). `dateModified = Date()` so the row sorts
  /// near the top of a Date-descending list — Finder's default
  /// orientation, where the user expects "freshly-being-created"
  /// to surface first. `resourceValues` on a missing path returns
  /// `nil` for every key, which would land the row at
  /// `.distantPast` and push it out of the visible window for
  /// large directories.
  public init(placeholder url: URL) {
    self.url = url
    self.name = url.lastPathComponent
    self.isDirectory = false
    self.isPackage = false
    self.isHidden = false
    self.isSymbolicLink = false
    self.size = 0
    self.dateModified = Date()
    self.kind = "—"
  }

  /// Table-cell display for the Size column. Directories omit size the
  /// way Finder does — showing "--" rather than the inode's zero byte
  /// count keeps the column readable when browsing deep trees.
  public var displaySize: String {
    if isDirectory && !isPackage { return "--" }
    return Self.byteFormatter.string(fromByteCount: size)
  }

  /// Table-cell display for the Date Modified column. Matches Finder's
  /// default list view: today renders as "Today at 14:22", yesterday
  /// as "Yesterday at 09:15", and anything older as a calendar date
  /// plus short time. `DateFormatter.doesRelativeDateFormatting` does
  /// the today/yesterday substitution automatically and follows the
  /// system locale (Japanese users see "今日 14:22" / "昨日 09:15").
  /// Items whose modification time isn't available render as `—`.
  ///
  /// This used to call `RelativeDateTimeFormatter.localizedString`
  /// ("3 hours ago" / "2 weeks ago"), but that formatter returns
  /// "0 seconds ago" for freshly touched files and diverges from the
  /// Finder List View look the pane is meant to mirror.
  public var displayDate: String {
    guard let dateModified else { return "—" }
    return Self.dateFormatter.string(from: dateModified)
  }

  public var displayKind: String { kind }

  // `ByteCountFormatter` is not `Sendable`, but
  // `string(fromByteCount:)` is thread-safe in practice and FileItem
  // itself is now nonisolated so callers may reach this from off
  // the main actor. `DateFormatter` (below) gained Sendable on
  // macOS 26 so it doesn't need the escape hatch.
  nonisolated(unsafe) private static let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    // Finder renders 0-byte files as "0 bytes" / "0 バイト" (numeric),
    // not the default "Zero KB" the formatter would produce with the
    // non-numeric flag on. Verified against macOS Finder's own list
    // view. Other sizes (20 bytes, 4 KB, 77 MB) render identically
    // under both flag values; only the zero case differs.
    f.allowsNonnumericFormatting = false
    return f
  }()

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    // Today / Yesterday get substituted automatically; every other
    // date falls through to the medium calendar format ("Apr 15, 2026"
    // / "2026/04/15" depending on locale).
    f.doesRelativeDateFormatting = true
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()
}
