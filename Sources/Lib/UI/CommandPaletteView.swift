import AppKit

/// Global command palette overlay shown at the top-center of the window.
///
/// Fully frame-based layout — no Auto Layout constraints. This matches
/// `SuggestionListView`'s own frame-based height management and avoids
/// the circular dependency that occurs when mixing Auto Layout with
/// `SuggestionListView.update(items:)` which sets `frame.size.height`
/// directly.
///
/// Lifecycle:
/// - `show(in:)` adds the palette to the window, focuses the text field
/// - `dismiss()` removes it and returns focus to the previous responder
/// - `toggle(in:)` switches between the two
@MainActor
public final class CommandPaletteView: NSView, NSTextFieldDelegate {
    private let inputField = NSTextField()
    private let divider = NSBox()
    private let suggestionList = SuggestionListView()

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

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setup() {
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        layer?.cornerRadius = 10
        layer?.borderColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        layer?.borderWidth = 1
        shadow = NSShadow()
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.5).cgColor
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 16
        layer?.shadowOffset = CGSize(width: 0, height: -6)

        // Input field — frame-based, positioned in layoutSubviews().
        inputField.placeholderString = "Execute a command\u{2026}"
        inputField.font = .systemFont(ofSize: 16, weight: .light)
        inputField.textColor = .white
        inputField.backgroundColor = .clear
        inputField.isBordered = false
        inputField.focusRingType = .none
        inputField.cell?.isScrollable = true
        inputField.delegate = self
        addSubview(inputField)

        // Divider — thin line between input and list.
        divider.boxType = .separator
        addSubview(divider)

        // Suggestion list — frame-based, same pattern as PaneURLBar.
        addSubview(suggestionList)
        suggestionList.onSelectIndex = { [weak self] index in
            self?.executeAction(at: index)
        }
    }

    // MARK: - Cursor

    public override func cursorUpdate(with event: NSEvent) {
        // Prevent background elements from changing the cursor over the
        // palette's non-input areas (divider, padding).
        let local = convert(event.locationInWindow, from: nil)
        if inputField.frame.contains(local) {
            NSCursor.iBeam.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    // MARK: - Flipped coordinates

    // Use top-down coordinates so Y=0 is the top of the palette.
    // This makes frame calculations straightforward: input at Y=8,
    // divider below, suggestion list below that.
    public override var isFlipped: Bool { true }

    // MARK: - Layout

    /// Reposition subviews within the palette. Called after the palette
    /// frame is set or the suggestion list content changes.
    private func layoutSubviews() {
        let w = bounds.width
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

    /// Compute the total palette height and position it at the top-center
    /// of the window's contentView.
    private func layoutInWindow(_ contentView: NSView) {
        let availableWidth = contentView.bounds.width - 40
        let width = min(containerWidth, availableWidth)
        let listHeight = suggestionList.isHidden ? 0 : suggestionList.frame.height
        let totalHeight = inputAreaHeight + listHeight

        let x = (contentView.bounds.width - width) / 2
        // AppKit Y=0 is bottom. Top of the window minus margin minus palette height.
        let y = contentView.bounds.height - totalHeight - topMargin
        frame = NSRect(x: x, y: y, width: width, height: totalHeight)

        layoutSubviews()
    }

    // MARK: - Public API

    /// Whether the palette is currently visible.
    public var isVisible: Bool { superview != nil }

    /// Show the palette in the given window. Positions itself at the
    /// top-center and focuses the text field.
    public func show(in window: NSWindow) {
        guard let contentView = window.contentView else { return }
        if superview !== contentView {
            removeFromSuperview()
            contentView.addSubview(self)
        }

        inputField.stringValue = ""
        let items = onSearch?("") ?? []
        suggestionList.update(items: items)

        layoutInWindow(contentView)
        window.makeFirstResponder(inputField)
    }

    /// Hide the palette and notify the host. Idempotent — safe to call
    /// when already dismissed (e.g. "Command Palette" action triggers
    /// `toggleCommandPalette` which dismisses first, then `executeAction`
    /// calls `dismiss` again).
    public func dismiss() {
        guard isVisible else { return }
        suggestionList.dismiss()
        removeFromSuperview()
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

    // MARK: - Window Resize

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResize),
                name: NSWindow.didResizeNotification, object: window)
        }
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let contentView = window?.contentView, isVisible else { return }
        layoutInWindow(contentView)
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

        if let contentView = window?.contentView {
            layoutInWindow(contentView)
        }
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
        // Focus loss dismisses the palette (ghostty behavior).
        // Delay check to avoid dismissing when focus moves to the field
        // editor (NSTextView) which is a descendant of this view.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            if let responder = self.window?.firstResponder as? NSView,
               responder.isDescendant(of: self) {
                return
            }
            self.dismiss()
        }
    }
}
