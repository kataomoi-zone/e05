import AppKit

/// Global command palette overlay shown at the top-center of the window.
///
/// Hosted in a child NSPanel so the OS routes hover, click, and cursor
/// events to the palette window first — same pattern as the URL bar
/// suggestion dropdown. The previous in-window subview let the
/// underlying WKWebView keep firing `:hover` events through the
/// translucent card; the cross-window split blocks that.
///
/// The card surface is `NSGlassEffectView` (macOS 26 Liquid Glass), so
/// the palette inherits the same material as the sidebar and pane
/// chrome rather than the prior flat translucent fill.
///
/// Layout inside the palette stays frame-based (positions written by
/// `layoutSubviews`) — that matches `SuggestionListView.update(items:)`
/// which sets `frame.size.height` directly, and avoids the circular
/// dependency that would arise mixing Auto Layout with self-sized
/// content.
///
/// Lifecycle:
/// - `show(in:)` orders the panel front and focuses the text field
/// - `dismiss()` orders the panel out and notifies the host
/// - `toggle(in:)` switches between the two
@MainActor
public final class CommandPaletteView: NSView, NSTextFieldDelegate {
  private let inputField = NSTextField()
  private let divider = NSBox()
  private let suggestionList = SuggestionListView()
  private let glass = NSGlassEffectView()
  /// `card.isFlipped = true` so the frame-based layout below can keep
  /// using top-down y coordinates after the subview tree moved inside
  /// the glass effect view (an ordinary, non-flipped NSView).
  private let card = FlippedView()

  private let containerWidth: CGFloat = 500
  private let inputHeight: CGFloat = 24
  private let topPadding: CGFloat = 8
  private let dividerPadding: CGFloat = 4
  private let dividerHeight: CGFloat = 1
  private let topMargin: CGFloat = 40

  /// Height of the input area: top padding + field + bottom padding + divider.
  private var inputAreaHeight: CGFloat {
    topPadding + inputHeight + dividerPadding + dividerHeight
  }

  /// Called on every keystroke. Receives the query string; returns cell
  /// models for display.
  public var onSearch: ((String) -> [SuggestionCellModel])?

  /// Called when the user selects an item (Enter or click). Receives
  /// the index into the array last returned by `onSearch`.
  public var onExecute: ((Int) -> Void)?

  /// Called when the palette is dismissed (Escape or focus loss) so that
  /// the host can restore keyboard focus to the appropriate pane.
  public var onDismiss: (() -> Void)?

  /// Child NSPanel that hosts this view. Lazily created on first show.
  /// Lives at `popUpMenu` level over the parent window so it draws
  /// above all pane content; `canBecomeKey = true` (via the subclass
  /// override) so the input field actually receives keystrokes.
  private var panel: NSPanel?

  /// Observer for the parent window's resize. Registered against the
  /// parent rather than `self.window` because, after the child-panel
  /// migration, `self.window` resolves to the panel and the panel
  /// never resizes on its own.
  /// `nonisolated(unsafe)` lets `deinit` release the token under
  /// Swift 6 strict concurrency.
  nonisolated(unsafe) private var parentResizeObserver: NSObjectProtocol?

  public override init(frame: NSRect) {
    super.init(frame: frame)
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  deinit {
    if let token = parentResizeObserver {
      NotificationCenter.default.removeObserver(token)
    }
    // The panel↔self retain pair is left intact: the host owns the
    // palette for the process lifetime, so the cycle never has a
    // chance to leak. Touching MainActor-isolated `NSWindow` methods
    // here would trip Swift 6 strict-concurrency in a nonisolated
    // deinit. A future multi-window split that releases palettes
    // mid-session can route cleanup through an explicit teardown
    // hook on the owning controller.
  }

  // MARK: - Setup

  private func setup() {
    appearance = NSAppearance(named: .darkAqua)

    // Glass surface with rounded clip. The 12pt radius matches the
    // sidebar / pane chrome so the palette reads as the same material
    // tier when it overlaps them.
    glass.translatesAutoresizingMaskIntoConstraints = false
    card.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView = card
    glass.wantsLayer = true
    glass.layer?.cornerRadius = AppMetrics.surfaceCornerRadius
    glass.layer?.cornerCurve = .continuous
    glass.layer?.masksToBounds = true
    addSubview(glass)
    NSLayoutConstraint.activate([
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    inputField.placeholderString = "Execute a command\u{2026}"
    inputField.font = .systemFont(ofSize: 16, weight: .light)
    inputField.textColor = .white
    inputField.backgroundColor = .clear
    inputField.isBordered = false
    inputField.focusRingType = .none
    inputField.cell?.isScrollable = true
    inputField.delegate = self
    card.addSubview(inputField)

    divider.boxType = .separator
    card.addSubview(divider)

    card.addSubview(suggestionList)
    suggestionList.onSelectIndex = { [weak self] index in
      self?.executeAction(at: index)
    }
  }

  // MARK: - Layout

  /// Reposition the input row, divider, and suggestion list within the
  /// glass card. Called after the panel frame is set or the suggestion
  /// list content changes. Reads `card.bounds.width` (== panel content
  /// width) and writes child frames in top-down coordinates because
  /// `card` is flipped.
  private func layoutSubviews() {
    let w = card.bounds.width
    inputField.frame = NSRect(
      x: 12, y: topPadding, width: w - 24, height: inputHeight)
    divider.frame = NSRect(
      x: 8, y: topPadding + inputHeight + dividerPadding,
      width: w - 16, height: 1)

    let listTop = inputAreaHeight
    let listHeight = suggestionList.isHidden ? 0 : suggestionList.frame.height
    suggestionList.frame = NSRect(
      x: 0, y: listTop, width: w, height: listHeight)
  }

  /// Compute the panel's screen rect and apply it. Also re-runs the
  /// internal subview layout because `card.bounds` only updates after
  /// AppKit propagates `panel.setFrame` through the contentView chain.
  private func layoutInPanel() {
    guard let panel, let parent = panel.parent else { return }
    let parentFrame = parent.frame
    let availableWidth = parentFrame.width - 40
    let width = min(containerWidth, availableWidth)
    let listHeight = suggestionList.isHidden ? 0 : suggestionList.frame.height
    let totalHeight = inputAreaHeight + listHeight
    let panelX = parentFrame.minX + (parentFrame.width - width) / 2
    // Top-of-window minus margin minus palette height. Screen Y is
    // bottom-up, so panel.minY is the bottom edge.
    var panelY = parentFrame.maxY - totalHeight - topMargin

    // Clamp the panel's top edge to the screen's `visibleFrame`. The
    // parent window can sit above its host screen's visible area
    // under Stage Manager / split-screen / pre-fullscreen morph, in
    // which case the naive computation above pushes the panel off
    // the top of the display.
    if let screen = parent.screen ?? NSScreen.main {
      let visibleTop = screen.visibleFrame.maxY
      let panelTop = panelY + totalHeight
      if panelTop > visibleTop {
        panelY = visibleTop - totalHeight
      }
    }

    panel.setFrame(
      NSRect(x: panelX, y: panelY, width: width, height: totalHeight),
      display: true)
    layoutSubviews()
  }

  // MARK: - Public API

  /// Whether the palette panel is currently on screen.
  public var isVisible: Bool { panel?.isVisible ?? false }

  /// Show the palette over `window`, focus the input field, and start
  /// observing parent resize so the panel re-anchors on window resize.
  public func show(in window: NSWindow) {
    let panel = ensurePanel(parentWindow: window)

    inputField.stringValue = ""
    let items = onSearch?("") ?? []
    suggestionList.update(items: items)

    layoutInPanel()
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(inputField)

    if let token = parentResizeObserver {
      NotificationCenter.default.removeObserver(token)
    }
    parentResizeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.layoutInPanel() }
    }
  }

  /// Hide the palette and notify the host. Idempotent — safe to call
  /// when already dismissed (e.g. "Command Palette" action triggers
  /// `toggleCommandPalette` which dismisses first, then `executeAction`
  /// calls `dismiss` again).
  public func dismiss() {
    guard let panel, panel.isVisible else { return }
    if let token = parentResizeObserver {
      NotificationCenter.default.removeObserver(token)
      parentResizeObserver = nil
    }
    suggestionList.dismiss()
    panel.orderOut(nil)
    onDismiss?()
  }

  /// Toggle visibility.
  public func toggle(in window: NSWindow) {
    if isVisible {
      dismiss()
    } else {
      show(in: window)
    }
  }

  // MARK: - Panel lifecycle

  /// Build (or reattach) the child panel. Reparent guards against a
  /// future multi-window split — currently single-window, dead but
  /// cheap.
  private func ensurePanel(parentWindow: NSWindow) -> NSPanel {
    if let existing = panel {
      if existing.parent !== parentWindow {
        existing.parent?.removeChildWindow(existing)
        parentWindow.addChildWindow(existing, ordered: .above)
      }
      return existing
    }
    let p = CommandPalettePanel(
      contentRect: .zero,
      styleMask: [.borderless],
      backing: .buffered,
      defer: true
    )
    p.contentView = self
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .popUpMenu
    p.hidesOnDeactivate = true
    p.collectionBehavior = [.transient, .ignoresCycle]
    p.isReleasedWhenClosed = false
    parentWindow.addChildWindow(p, ordered: .above)
    panel = p
    return p
  }

  // MARK: - Action Execution

  private func executeAction(at index: Int) {
    onExecute?(index)
    dismiss()
  }

  // MARK: - NSTextFieldDelegate

  public func controlTextDidChange(_ notification: Notification) {
    let query = inputField.stringValue
    let items = onSearch?(query) ?? []
    suggestionList.update(items: items)
    layoutInPanel()
  }

  public func control(
    _ control: NSControl, textView _: NSTextView,
    doCommandBy selector: Selector
  ) -> Bool {
    if selector == #selector(insertNewline(_:)) {
      if let index = suggestionList.selectedIndex {
        executeAction(at: index)
      }
      return true
    }
    if selector == #selector(cancelOperation(_:)) {
      dismiss()
      return true
    }
    if selector == #selector(moveUp(_:)) {
      suggestionList.selectPrevious()
      return true
    }
    if selector == #selector(moveDown(_:)) {
      suggestionList.selectNext()
      return true
    }
    return false
  }

  public func controlTextDidEndEditing(_ notification: Notification) {
    // The input field can lose first responder when the parent window
    // becomes key (user clicked outside the panel) or when AppKit
    // tears down the field editor mid-focus-cycle. The deferred check
    // distinguishes the two: a real blur leaves `currentEditor()` nil
    // and the new first responder outside the palette tree, in which
    // case dismissing is the right move.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isVisible else { return }
      if let panel = self.panel,
        let responder = panel.firstResponder as? NSView,
        responder.isDescendant(of: self)
      {
        return
      }
      self.dismiss()
    }
  }
}

/// NSView subclass that flips its coordinate system. Used as the glass
/// content host so the palette's frame-based subview layout (written
/// in top-down coords) survives the move from `self` into
/// `glass.contentView`.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// Borderless panel that opts into key-window status. The default for
/// a borderless NSPanel is `canBecomeKey = false`, which would block
/// keyboard input to the palette's text field.
private final class CommandPalettePanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
