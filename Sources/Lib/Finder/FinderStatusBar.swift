import AppKit

/// 22pt strip along the bottom of a finder pane. Matches Finder's
/// status bar: item count on quiescent selection, selection count when
/// rows are highlighted, and volume free space on the trailing side.
@MainActor
final class FinderStatusBar: NSView {
  private let label = NSTextField(labelWithString: "")
  private let freeSpaceLabel = NSTextField(labelWithString: "")

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = AppColors.statusBarSurface.cgColor

    label.font = .systemFont(ofSize: 11)
    label.textColor = .secondaryLabelColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false

    freeSpaceLabel.font = .systemFont(ofSize: 11)
    freeSpaceLabel.textColor = .tertiaryLabelColor
    freeSpaceLabel.alignment = .right
    freeSpaceLabel.translatesAutoresizingMaskIntoConstraints = false

    addSubview(label)
    addSubview(freeSpaceLabel)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      freeSpaceLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      freeSpaceLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func update(totalCount: Int, selectedCount: Int, availableBytes: Int64?) {
    if selectedCount > 0 {
      label.stringValue = "\(selectedCount) of \(totalCount) selected"
    } else {
      label.stringValue = "\(totalCount) item\(totalCount == 1 ? "" : "s")"
    }
    if let bytes = availableBytes {
      freeSpaceLabel.stringValue = "\(Self.byteFormatter.string(fromByteCount: bytes)) available"
    } else {
      freeSpaceLabel.stringValue = ""
    }
  }

  // FinderStatusBar is MainActor-isolated, so the static formatter
  // inherits the same isolation; no `nonisolated` needed.
  private static let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    // Match Finder: zero free space (rare but possible on a full
    // volume) renders as "0 bytes" / "0 バイト" rather than "Zero KB".
    f.allowsNonnumericFormatting = false
    return f
  }()
}
