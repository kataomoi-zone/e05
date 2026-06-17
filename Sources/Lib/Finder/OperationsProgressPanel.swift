import AppKit

/// Floating progress panel for in-flight finder-pane batch ops
/// (Compress, Paste, Duplicate). Uses the same auxiliary `NSPanel`
/// pattern as `GetInfoPanel` — explicit exception to the one-window
/// invariant — so a multi-GB Compress that takes minutes shows the
/// user what's running, what's left, and offers a cancel without
/// crowding the main window.
///
/// One row per op: label ("Compressing node_modules.zip"),
/// indeterminate progress bar, and a ✕ cancel button when the op
/// supports it. The panel auto-shows on first `register` and
/// auto-closes when the last op unregisters; when no op is running
/// there is no UI surface, satisfying the "don't add a sidebar mode
/// that's empty most of the time" constraint.
///
/// A copy batch supplies a `FinderCopyProgress` byte tally, so its row
/// draws a determinate bar plus a "1.2 GB of 15 GB" subtitle, repainted
/// from a timer while the panel is up (the tally is written off-main by
/// the copy callback, so the panel polls it rather than the tracker
/// posting on every byte). Ops without a tally (Compress — `zip -q`
/// emits no byte counts) keep the indeterminate spinner.
@MainActor
public final class OperationsProgressPanel: NSPanel, NSWindowDelegate {
  /// Strong reference to the live panel so successive `showIfNeeded`
  /// invocations don't stack a second panel. Cleared in
  /// `windowWillClose(_:)` and again from `dismissIfEmpty()` so a
  /// closed panel never lingers on this slot.
  static var shared: OperationsProgressPanel?

  private let stackView = NSStackView()

  /// Per-op determinate bar + byte subtitle, keyed by id so the progress
  /// timer can repaint a row in place independently of the
  /// register/unregister-driven full rebuild. Cleared and repopulated by
  /// `refresh()`.
  private var progressBars: [FinderOperationTracker.OperationID: NSProgressIndicator] = [:]
  private var byteLabels: [FinderOperationTracker.OperationID: NSTextField] = [:]
  /// Repaints the determinate bars while the panel is up. The byte tally is
  /// written off-main by the copy callback at write frequency, so the panel
  /// polls it here rather than the tracker posting a notification per byte.
  private var progressTimer: Timer?
  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()

  /// `nonisolated(unsafe)` so Swift 6's nonisolated `deinit` can
  /// hand the token back to `NotificationCenter.removeObserver`
  /// without a MainActor hop. The token isn't `Sendable` but
  /// `removeObserver(_:)` is — it dereferences the token through
  /// thread-safe internal locking. Same workaround `FinderPaneView`
  /// uses for its `settingsObserver`.
  private nonisolated(unsafe) var observer: NSObjectProtocol?

  /// Hand back the cancel `OperationID` from the row's button.
  /// Custom subclass instead of `NSButton.tag` because tag is `Int`
  /// and our IDs are UUIDs — round-tripping through `hashValue`
  /// loses information and risks collision.
  private final class CancelButton: NSButton {
    var operationID: FinderOperationTracker.OperationID?
  }

  public override init(
    contentRect: NSRect, styleMask style: NSWindow.StyleMask,
    backing: NSWindow.BackingStoreType, defer flag: Bool
  ) {
    super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
  }

  public convenience init() {
    self.init(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
      styleMask: [.titled, .closable, .utilityWindow],
      backing: .buffered, defer: false)
    title = "Operations"
    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    delegate = self
    standardWindowButton(.zoomButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true

    let host = NSView()
    stackView.orientation = .vertical
    stackView.alignment = .leading
    stackView.spacing = 12
    stackView.distribution = .fill
    stackView.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    stackView.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(stackView)
    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: host.topAnchor),
      stackView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    contentView = host

    observer = NotificationCenter.default.addObserver(
      forName: FinderOperationTracker.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }

    refresh()

    // 10 Hz is smooth for a progress bar without churning the run loop; the
    // tick is a cheap dictionary walk that no-ops for indeterminate ops.
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.updateProgressBars() }
    }
  }

  deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Show the panel near `window` if at least one op is registered.
  /// No-op when the panel is already on screen — the existing
  /// instance refreshes itself via the notification observer. Idempotent
  /// across rapid `register`s, so callers can fire it on every op
  /// start without checking shared state.
  public static func showIfNeeded(near window: NSWindow?) {
    guard !FinderOperationTracker.shared.operations.isEmpty else { return }
    if Self.shared == nil {
      let panel = OperationsProgressPanel()
      Self.shared = panel
      panel.positionRelative(to: window)
      panel.orderFront(nil)
    }
  }

  /// Default deferral before a `scheduleShowIfNeeded` actually
  /// instantiates the panel. Ops that finish faster than this never
  /// make the panel flash, including any race where a `register` /
  /// `unregister` pair completes inside the window because the
  /// detached task happened to finish before its caller's `register`
  /// landed on the tracker.
  public static let panelShowDelay: TimeInterval = 0.5

  /// Show the panel after a short delay so trivially-fast ops
  /// (sub-second Compress / Paste / Duplicate) never make the panel
  /// flash on screen at all. The delayed check re-evaluates the
  /// tracker, so an op that finished inside the window finds zero
  /// operations and skips the show. Same idempotency as
  /// `showIfNeeded` for overlapping registrations.
  public static func scheduleShowIfNeeded(
    near window: NSWindow?, after delay: TimeInterval = panelShowDelay
  ) {
    let captured = window
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      MainActor.assumeIsolated { showIfNeeded(near: captured) }
    }
  }

  /// Close the panel when no ops remain. Called from the unregister
  /// path so the last op finishing also tears the panel down — keeps
  /// the user from staring at an empty "Operations" titlebar after
  /// the work is done.
  public static func dismissIfEmpty() {
    guard FinderOperationTracker.shared.operations.isEmpty else { return }
    Self.shared?.close()
    Self.shared = nil
  }

  private func positionRelative(to window: NSWindow?) {
    guard let window, let screen = window.screen ?? NSScreen.main else {
      center()
      return
    }
    let frame = window.frame
    var origin = NSPoint(
      x: frame.maxX - self.frame.width - 24,
      y: frame.minY + 24)
    let visible = screen.visibleFrame
    origin.x = min(max(origin.x, visible.minX), visible.maxX - self.frame.width)
    origin.y = min(max(origin.y, visible.minY), visible.maxY - self.frame.height)
    setFrameOrigin(origin)
  }

  public func windowWillClose(_ notification: Notification) {
    progressTimer?.invalidate()
    progressTimer = nil
    if Self.shared === self {
      Self.shared = nil
    }
  }

  private func refresh() {
    let ops = FinderOperationTracker.shared.operations
    if ops.isEmpty {
      Self.dismissIfEmpty()
      return
    }
    for view in stackView.arrangedSubviews {
      view.removeFromSuperview()
    }
    progressBars.removeAll()
    byteLabels.removeAll()
    for op in ops {
      stackView.addArrangedSubview(makeRow(op))
    }
    contentView?.layoutSubtreeIfNeeded()
    let fitting = stackView.fittingSize
    setContentSize(NSSize(width: 360, height: max(60, fitting.height)))
  }

  private func makeRow(_ op: FinderOperationTracker.Operation) -> NSView {
    let label = NSTextField(labelWithString: op.label)
    label.font = .systemFont(ofSize: 12)
    label.lineBreakMode = .byTruncatingMiddle
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let progress = NSProgressIndicator()
    progress.style = .bar
    progress.translatesAutoresizingMaskIntoConstraints = false
    progress.heightAnchor.constraint(equalToConstant: 6).isActive = true
    if op.progress != nil {
      // Determinate from creation: the timer drives doubleValue. Toggling an
      // animating indeterminate bar to determinate doesn't reliably stop the
      // barber-pole sweep (especially with threaded animation), so a
      // byte-tracked bar never animates — it sits empty for the brief
      // "preparing" size walk, then fills.
      progress.isIndeterminate = false
      progress.minValue = 0
      progress.maxValue = 1
      progress.doubleValue = 0
    } else {
      progress.isIndeterminate = true
      progress.usesThreadedAnimation = true
      progress.startAnimation(nil)
    }
    progressBars[op.id] = progress

    var textColViews: [NSView] = [label, progress]
    if op.progress != nil {
      let detail = NSTextField(labelWithString: "")
      detail.font = .systemFont(ofSize: 10)
      detail.textColor = .secondaryLabelColor
      detail.lineBreakMode = .byTruncatingTail
      detail.translatesAutoresizingMaskIntoConstraints = false
      detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
      byteLabels[op.id] = detail
      textColViews.append(detail)
    }

    let textCol = NSStackView(views: textColViews)
    textCol.orientation = .vertical
    textCol.alignment = .leading
    textCol.spacing = 4
    textCol.distribution = .fill
    textCol.translatesAutoresizingMaskIntoConstraints = false
    textCol.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView()
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.distribution = .fill
    row.translatesAutoresizingMaskIntoConstraints = false
    row.addArrangedSubview(textCol)

    if op.cancel != nil {
      let cancelButton = CancelButton()
      cancelButton.image = NSImage(
        systemSymbolName: "xmark.circle.fill",
        accessibilityDescription: "Cancel \(op.label)")
      cancelButton.isBordered = false
      cancelButton.bezelStyle = .regularSquare
      cancelButton.imagePosition = .imageOnly
      cancelButton.target = self
      cancelButton.action = #selector(cancelClicked(_:))
      cancelButton.operationID = op.id
      cancelButton.translatesAutoresizingMaskIntoConstraints = false
      cancelButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
      cancelButton.heightAnchor.constraint(equalToConstant: 18).isActive = true
      cancelButton.setContentHuggingPriority(.required, for: .horizontal)
      row.addArrangedSubview(cancelButton)
    }

    NSLayoutConstraint.activate([
      row.widthAnchor.constraint(equalToConstant: 336)
    ])
    return row
  }

  /// Pull each byte-tracked op's latest fraction and repaint its bar +
  /// subtitle. A byte-tracked op still in its preparing phase
  /// (`fraction == nil`, total not yet tallied) is left at its empty
  /// determinate bar — it doesn't animate. An op with no tally at all
  /// (Compress) is skipped here and keeps the indeterminate spinner its
  /// row started with.
  private func updateProgressBars() {
    for op in FinderOperationTracker.shared.operations {
      guard let bar = progressBars[op.id], let progress = op.progress,
        let fraction = progress.fraction
      else { continue }
      bar.doubleValue = fraction
      if let summary = progress.byteSummary, let detail = byteLabels[op.id] {
        detail.stringValue =
          "\(Self.byteFormatter.string(fromByteCount: summary.copied)) of "
          + Self.byteFormatter.string(fromByteCount: summary.total)
      }
    }
  }

  @objc private func cancelClicked(_ sender: CancelButton) {
    guard let id = sender.operationID else { return }
    FinderOperationTracker.shared.cancel(id)
  }
}
