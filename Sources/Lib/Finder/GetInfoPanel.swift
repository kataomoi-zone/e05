import AppKit

/// Read-only inspector panel for a single filesystem entry, modelled
/// on Finder's "Get Info" window. Lives as an auxiliary `NSPanel`
/// so it's an explicit exception to e05's one-window invariant —
/// Quick Look's `QLPreviewPanel` is the existing precedent. The
/// panel is non-modal, floats above the main window, and tears
/// itself down on close so successive Get Info invocations don't
/// stack. Tag editing, Open With, and the preview/thumbnail well
/// are out of scope for this iteration; users get the seven
/// metadata rows that account for almost every Get Info read.
@MainActor
public final class GetInfoPanel: NSPanel, NSWindowDelegate {
  /// Strong reference to the live panel so `present(for:near:)` can
  /// dismiss it before opening a new one. Cleared in
  /// `windowWillClose(_:)` (the user-facing close path) and again
  /// from `present` before allocating the replacement, so a closed
  /// panel never lingers on this slot.
  static var shared: GetInfoPanel?

  private let url: URL

  public init(url: URL) {
    self.url = url
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
      styleMask: [.titled, .closable, .resizable, .utilityWindow],
      backing: .buffered, defer: false)
    title = "\(url.lastPathComponent) Info"
    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    // `isReleasedWhenClosed = false` keeps AppKit from over-releasing
    // a panel we're still holding via `Self.shared`; the strong
    // reference + `windowWillClose` is what actually frees it.
    isReleasedWhenClosed = false
    delegate = self
    // Hide the zoom (green) and miniaturize (yellow) traffic-light
    // slots: there's no maximised view of a metadata panel that
    // would help, miniaturizing it loses the panel into the dock
    // when its raison d'être is to sit next to the pane, and
    // omitting `.miniaturizable` from the style mask alone leaves
    // the slot rendered as a disabled grey dot. `.resizable` stays
    // so the user can still drag the corner to widen the panel for
    // long paths.
    standardWindowButton(.zoomButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true

    // Pin the stack to top / leading / trailing of the host and the
    // bottom *equal* (not `<=`) so the host's intrinsic height
    // tracks the stack's fitting size. Combined with `setContentSize`
    // below, that makes the panel auto-fit when long paths wrap to
    // many lines instead of clipping the bottom rows.
    let host = NSView()
    let stack = makeContent()
    host.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: host.topAnchor),
      stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    contentView = host
    host.layoutSubtreeIfNeeded()
    let fittingHeight = stack.fittingSize.height
    setContentSize(NSSize(width: 320, height: fittingHeight))
  }

  /// Open a Get Info panel for `url`, replacing any existing panel.
  /// Always builds a fresh instance so metadata (size/mtime/icon)
  /// reflects the current filesystem state — otherwise a
  /// re-invocation on the same URL after an external write would
  /// keep the previous panel's stale values. No-op when the file
  /// is gone by the time the click arrives, since the resulting
  /// half-empty panel is more confusing than useful.
  public static func present(for url: URL, near window: NSWindow?) {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return
    }
    Self.shared?.close()
    Self.shared = nil
    let panel = GetInfoPanel(url: url)
    Self.shared = panel
    panel.positionRelative(to: window)
    panel.makeKeyAndOrderFront(nil)
  }

  /// Place the panel near `window`'s centre, then clamp the result
  /// to the window's screen `visibleFrame` so a small secondary
  /// display or a near-edge main window can't push the panel
  /// fully off-screen. Falls back to `center()` when there's no
  /// window or screen reference yet.
  private func positionRelative(to window: NSWindow?) {
    guard let window, let screen = window.screen ?? NSScreen.main else {
      center()
      return
    }
    let frame = window.frame
    var origin = NSPoint(
      x: frame.midX - self.frame.width / 2,
      y: frame.midY - self.frame.height / 2)
    let visible = screen.visibleFrame
    origin.x = min(max(origin.x, visible.minX), visible.maxX - self.frame.width)
    origin.y = min(max(origin.y, visible.minY), visible.maxY - self.frame.height)
    setFrameOrigin(origin)
  }

  /// Drop the static reference when the user clicks the red dot —
  /// without this, `isReleasedWhenClosed = false` keeps the closed
  /// panel alive in the autorelease pool and `Self.shared` would
  /// still point at it, breaking the next invocation's
  /// "always fresh metadata" guarantee.
  public func windowWillClose(_ notification: Notification) {
    if Self.shared === self {
      Self.shared = nil
    }
  }

  // MARK: - Content

  private func makeContent() -> NSView {
    let root = NSStackView()
    root.orientation = .vertical
    root.alignment = .leading
    root.distribution = .fill
    root.spacing = 12
    root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    root.translatesAutoresizingMaskIntoConstraints = false

    // Header: large icon + name + kind/size summary, mirroring
    // Finder's title block. Icon resolution goes through Launch
    // Services so package icons and custom icons match Finder.
    let header = NSStackView()
    header.orientation = .horizontal
    header.alignment = .top
    header.spacing = 12
    header.translatesAutoresizingMaskIntoConstraints = false

    let iconView = NSImageView()
    iconView.image = NSWorkspace.shared.icon(
      forFile: url.path(percentEncoded: false))
    iconView.imageScaling = .scaleProportionallyDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
    iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true

    let nameLabel = NSTextField(labelWithString: url.lastPathComponent)
    nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    nameLabel.lineBreakMode = .byTruncatingMiddle
    nameLabel.maximumNumberOfLines = 2
    let summary = headerSummary()
    let summaryLabel = NSTextField(labelWithString: summary)
    summaryLabel.font = .systemFont(ofSize: 11)
    summaryLabel.textColor = .secondaryLabelColor

    let titleStack = NSStackView(views: [nameLabel, summaryLabel])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 2

    header.addArrangedSubview(iconView)
    header.addArrangedSubview(titleStack)

    root.addArrangedSubview(header)
    root.addArrangedSubview(NSBox.separator())

    // Detail grid: one labeled row per metadata field. NSGridView
    // would also work, but the existing finder-pane stack-of-rows
    // pattern keeps the styling consistent with FinderStatusBar
    // and the rest of the pane.
    for (label, value) in detailRows() {
      root.addArrangedSubview(detailRow(label: label, value: value))
    }

    return root
  }

  private func detailRow(label: String, value: String) -> NSView {
    let labelField = NSTextField(labelWithString: label)
    labelField.font = .systemFont(ofSize: 11, weight: .semibold)
    labelField.textColor = .secondaryLabelColor
    labelField.alignment = .right
    labelField.translatesAutoresizingMaskIntoConstraints = false
    labelField.widthAnchor.constraint(equalToConstant: 84).isActive = true
    labelField.setContentHuggingPriority(.required, for: .horizontal)

    // `cell?.wraps = true` is the AppKit incantation that gets a
    // label-style NSTextField to actually word-wrap multi-line
    // content instead of single-line truncating; setting
    // `lineBreakMode` and `maximumNumberOfLines` alone isn't
    // enough on macOS 26. Long paths (`/Users/.../deep/nested/file`)
    // therefore lay out across as many lines as needed instead of
    // ellipsing past the panel edge.
    let valueField = NSTextField(wrappingLabelWithString: value)
    valueField.font = .systemFont(ofSize: 11)
    valueField.isSelectable = true
    valueField.translatesAutoresizingMaskIntoConstraints = false
    valueField.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [labelField, valueField])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.distribution = .fill
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
  }

  // MARK: - Metadata

  private func headerSummary() -> String {
    let kind = (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
      .localizedTypeDescription) ?? "—"
    if let bytes = totalSizeBytes() {
      return "\(kind) — \(Self.byteFormatter.string(fromByteCount: bytes))"
    }
    return kind
  }

  private func detailRows() -> [(String, String)] {
    var rows: [(String, String)] = []
    let keys: [URLResourceKey] = [
      .creationDateKey,
      .contentModificationDateKey,
      .fileSizeKey,
      .isDirectoryKey,
    ]
    let values = try? url.resourceValues(forKeys: Set(keys))

    rows.append(("Where:", url.deletingLastPathComponent().path(percentEncoded: false)))

    if let bytes = totalSizeBytes() {
      rows.append(("Size:", Self.byteFormatter.string(fromByteCount: bytes)))
    }

    if let created = values?.creationDate {
      rows.append(("Created:", Self.dateFormatter.string(from: created)))
    }
    if let modified = values?.contentModificationDate {
      rows.append(("Modified:", Self.dateFormatter.string(from: modified)))
    }

    if let perms = posixPermissions() {
      rows.append(("Permissions:", perms))
    }
    rows.append(("Full Path:", url.path(percentEncoded: false)))
    return rows
  }

  /// Total bytes the entry occupies on disk. For a regular file
  /// `fileSize` is enough; for a directory we walk recursively
  /// (single-shot, on the main actor) because Finder's Get Info
  /// shows aggregated size. Recursive enumeration on a multi-GB
  /// tree could stall the panel open — acceptable trade-off for a
  /// one-shot inspector window.
  ///
  /// TODO: cap or async-refresh once the user hits a tree where
  /// this freezes meaningfully (`~/Library`, monorepo `node_modules`).
  /// Likely shape: enumerate off-main with `Task.detached`, render
  /// "Calculating…" first, then populate the row when the walk
  /// completes; cancel the task on panel close.
  private func totalSizeBytes() -> Int64? {
    let isDirectory =
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    if !isDirectory {
      if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        return Int64(size)
      }
      return nil
    }
    var total: Int64 = 0
    if let enumerator = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    {
      for case let entry as URL in enumerator {
        let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values?.isRegularFile == true, let size = values?.fileSize {
          total += Int64(size)
        }
      }
    }
    return total
  }

  /// Render the entry's POSIX mode bits as `rwxr-xr-x`. The mode
  /// comes from `FileManager.attributesOfItem(atPath:)` because
  /// `URLResourceKey` doesn't surface a unix-style mode field.
  private func posixPermissions() -> String? {
    guard
      let attrs = try? FileManager.default.attributesOfItem(
        atPath: url.path(percentEncoded: false)),
      let raw = attrs[.posixPermissions] as? NSNumber
    else { return nil }
    let mode = raw.uint16Value
    var out = ""
    let bits: [(UInt16, String)] = [
      (0o400, "r"), (0o200, "w"), (0o100, "x"),
      (0o040, "r"), (0o020, "w"), (0o010, "x"),
      (0o004, "r"), (0o002, "w"), (0o001, "x"),
    ]
    for (bit, char) in bits {
      out.append(mode & bit != 0 ? char : "-")
    }
    return out
  }

  // MARK: - Formatters

  private static let byteFormatter: ByteCountFormatter = {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f
  }()

  private static let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()
}

extension NSBox {
  fileprivate static func separator() -> NSBox {
    let b = NSBox()
    b.boxType = .separator
    return b
  }
}
