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
/// Real progress (per-file fraction for Compress, byte-counts for
/// copy) is deferred — `zip -q` emits nothing, `FileManager.copyItem`
/// doesn't expose bytes. The indeterminate spinner is enough to make
/// "something is happening" obvious; precise progress sources land
/// in a follow-up phase.
@MainActor
public final class OperationsProgressPanel: NSPanel, NSWindowDelegate {
  /// Strong reference to the live panel so successive `showIfNeeded`
  /// invocations don't stack a second panel. Cleared in
  /// `windowWillClose(_:)` and again from `dismissIfEmpty()` so a
  /// closed panel never lingers on this slot.
  static var shared: OperationsProgressPanel?

  private let stackView = NSStackView()
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
    progress.isIndeterminate = true
    progress.usesThreadedAnimation = true
    progress.translatesAutoresizingMaskIntoConstraints = false
    progress.heightAnchor.constraint(equalToConstant: 6).isActive = true
    progress.startAnimation(nil)

    let textCol = NSStackView(views: [label, progress])
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
      row.widthAnchor.constraint(equalToConstant: 336),
    ])
    return row
  }

  @objc private func cancelClicked(_ sender: CancelButton) {
    guard let id = sender.operationID else { return }
    FinderOperationTracker.shared.cancel(id)
  }
}
