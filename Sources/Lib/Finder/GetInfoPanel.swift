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

  /// Captured at content-build time so the async size walk can
  /// patch both the header summary line and the "Size:" row when
  /// it completes (or is cancelled). `nil` for non-directory entries
  /// where the size is resolved synchronously.
  private var summaryLabel: NSTextField?
  private var sizeValueLabel: NSTextField?

  /// Off-main directory walk for aggregated size. Cancelled in
  /// `windowWillClose` so closing the panel mid-walk on a multi-GB
  /// tree (`~/Library`, `node_modules`) stops the enumeration
  /// instead of churning until completion.
  private var sizeTask: Task<Void, Never>?

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
  /// "always fresh metadata" guarantee. Also cancels the directory
  /// size walk so closing the panel during a multi-GB enumeration
  /// stops the walk at the next iteration boundary.
  public func windowWillClose(_ notification: Notification) {
    sizeTask?.cancel()
    sizeTask = nil
    if Self.shared === self {
      Self.shared = nil
    }
  }

  // MARK: - Content

  private func makeContent() -> NSView {
    let isDirectory =
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    let kind =
      (try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
        .localizedTypeDescription) ?? "—"
    let fileBytes: Int64? =
      isDirectory
      ? nil
      : (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }

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

    let summaryLabel = NSTextField(
      labelWithString: summaryString(kind: kind, isDirectory: isDirectory, bytes: fileBytes))
    summaryLabel.font = .systemFont(ofSize: 11)
    summaryLabel.textColor = .secondaryLabelColor
    self.summaryLabel = summaryLabel

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
    let dateValues = try? url.resourceValues(forKeys: [
      .creationDateKey, .contentModificationDateKey,
    ])

    root.addArrangedSubview(
      detailRow(
        label: "Where:",
        value: url.deletingLastPathComponent().path(percentEncoded: false)))

    if isDirectory {
      let field = makeValueField(initial: "Calculating…")
      self.sizeValueLabel = field
      root.addArrangedSubview(detailRow(label: "Size:", valueField: field))
    } else if let bytes = fileBytes {
      root.addArrangedSubview(
        detailRow(label: "Size:", value: Self.byteFormatter.string(fromByteCount: bytes)))
    }

    if let created = dateValues?.creationDate {
      root.addArrangedSubview(
        detailRow(label: "Created:", value: Self.dateFormatter.string(from: created)))
    }
    if let modified = dateValues?.contentModificationDate {
      root.addArrangedSubview(
        detailRow(label: "Modified:", value: Self.dateFormatter.string(from: modified)))
    }
    if let perms = posixPermissions() {
      root.addArrangedSubview(detailRow(label: "Permissions:", value: perms))
    }
    root.addArrangedSubview(
      detailRow(label: "Full Path:", value: url.path(percentEncoded: false)))

    if isDirectory {
      startDirectorySizeTask(kind: kind)
    }

    return root
  }

  private func summaryString(kind: String, isDirectory: Bool, bytes: Int64?) -> String {
    if isDirectory {
      return "\(kind) — Calculating…"
    }
    if let bytes {
      return "\(kind) — \(Self.byteFormatter.string(fromByteCount: bytes))"
    }
    return kind
  }

  private func makeValueField(initial: String) -> NSTextField {
    // `cell?.wraps = true` is the AppKit incantation that gets a
    // label-style NSTextField to actually word-wrap multi-line
    // content instead of single-line truncating; setting
    // `lineBreakMode` and `maximumNumberOfLines` alone isn't
    // enough on macOS 26. Long paths (`/Users/.../deep/nested/file`)
    // therefore lay out across as many lines as needed instead of
    // ellipsing past the panel edge.
    let field = NSTextField(wrappingLabelWithString: initial)
    field.font = .systemFont(ofSize: 11)
    field.isSelectable = true
    field.translatesAutoresizingMaskIntoConstraints = false
    field.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return field
  }

  private func detailRow(label: String, value: String) -> NSView {
    detailRow(label: label, valueField: makeValueField(initial: value))
  }

  private func detailRow(label: String, valueField: NSTextField) -> NSView {
    let labelField = NSTextField(labelWithString: label)
    labelField.font = .systemFont(ofSize: 11, weight: .semibold)
    labelField.textColor = .secondaryLabelColor
    labelField.alignment = .right
    labelField.translatesAutoresizingMaskIntoConstraints = false
    labelField.widthAnchor.constraint(equalToConstant: 84).isActive = true
    labelField.setContentHuggingPriority(.required, for: .horizontal)

    let row = NSStackView(views: [labelField, valueField])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.distribution = .fill
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    return row
  }

  // MARK: - Async size walk

  /// Kick off the off-main directory walk. The captured `kind`
  /// string is reused when patching the header summary so the
  /// resource-key lookup runs once on MainActor instead of being
  /// repeated on completion (which would also pull MainActor work
  /// back through the URL's bridged Cocoa value type).
  private func startDirectorySizeTask(kind: String) {
    let capturedURL = url
    sizeTask = Task.detached { [weak self] in
      let bytes = Self.directorySize(at: capturedURL)
      if Task.isCancelled { return }
      await MainActor.run {
        self?.applyDirectorySize(bytes, kind: kind)
      }
    }
  }

  private func applyDirectorySize(_ bytes: Int64?, kind: String) {
    if let bytes {
      let formatted = Self.byteFormatter.string(fromByteCount: bytes)
      sizeValueLabel?.stringValue = formatted
      summaryLabel?.stringValue = "\(kind) — \(formatted)"
    } else {
      sizeValueLabel?.stringValue = "—"
      summaryLabel?.stringValue = kind
    }
  }

  /// Recursive byte total for a directory. Runs off the main actor
  /// so a multi-GB tree (`~/Library`, monorepo `node_modules`)
  /// doesn't stall the panel open. The `Task.isCancelled` check
  /// inside the loop is what lets `windowWillClose` short-circuit
  /// an in-flight walk on close — note that each underlying
  /// `readdir` is uninterruptible, so on slow filesystems
  /// (NFS / SMB) the cancel only takes effect between entries.
  nonisolated private static func directorySize(at url: URL) -> Int64? {
    guard
      let enumerator = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
    else { return nil }
    var total: Int64 = 0
    for case let entry as URL in enumerator {
      if Task.isCancelled { return nil }
      let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      if values?.isRegularFile == true, let size = values?.fileSize {
        total += Int64(size)
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
