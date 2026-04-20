import AppKit

/// Shared URL bar for all pane types. Displays the current address and allows navigation.
/// Toggleable visibility — when hidden, PaneHeaderView serves as fallback notification.
@MainActor
public final class PaneURLBar: NSView, NSTextFieldDelegate {
    public static let barHeight: CGFloat = 28

    private let backButton: HoverIconButton
    private let forwardButton: HoverIconButton
    private let reloadButton: HoverIconButton
    private let foldButton: HoverIconButton
    private let urlField: NSTextField
    private let suggestionList = SuggestionListView()
    /// Domain objects backing the current dropdown. `SuggestionListView`
    /// only knows about cell models (index-addressable), so we retain the
    /// originals here and translate between index ↔ `Suggestion` at the
    /// boundary.
    private var currentSuggestions: [Suggestion] = []
    private var searchDebounceTimer: Timer?
    private static let searchDebounceInterval: TimeInterval = 0.15

    /// Inline zoom indicator (percent label + -/+/Reset). Hidden while
    /// `pageZoom` is at 1.0 so the URL field claims the full trailing
    /// space; revealed and updated via `setZoomPercent(_:)` whenever the
    /// focused browser pane reports a non-default zoom.
    let zoomContainer = NSStackView()
    let zoomPercentLabel = NSTextField(labelWithString: "")
    private let zoomOutInlineButton: HoverIconButton
    private let zoomInInlineButton: HoverIconButton
    private let zoomResetInlineButton = HoverIconButton(frame: .zero)

    /// Active URL-field trailing constraint. Swapped between the zoom
    /// container and the fold button in `setZoomPercent(_:)` so hiding
    /// the indicator lets the URL field reclaim the trailing slot.
    var urlTrailingToZoom: NSLayoutConstraint?
    var urlTrailingToFold: NSLayoutConstraint?

    /// Threshold under which `setZoomPercent(_:)` treats the supplied
    /// value as the 1.0 default. Wider than typical double round-trip
    /// error (e.g. `1.1 * (1/1.1)` leaves ~4e-16) so repeated zoom
    /// in/out keeps snapping the indicator back to hidden.
    private static let zoomDefaultEpsilon: CGFloat = 0.001

    /// Called when user submits a URL (presses Enter).
    public var onNavigate: ((String) -> Void)?
    /// Called when user clicks back button.
    public var onBack: (() -> Void)?
    /// Called when user clicks forward button.
    public var onForward: (() -> Void)?
    /// Called when user clicks the reload button.
    public var onReload: (() -> Void)?
    /// Called when user presses ESC to dismiss URL field.
    public var onCancel: (() -> Void)?
    /// Called when text changes in the URL field. Return suggestions to display.
    public var onTextChanged: ((String) -> [Suggestion])?
    /// Called when the URL bar is clicked (for pane focus management).
    public var onClicked: (() -> Void)?
    /// Called when user clicks the fold button.
    public var onFold: (() -> Void)?
    /// Called when the inline zoom indicator's "-" button is clicked.
    public var onZoomOut: (() -> Void)?
    /// Called when the inline zoom indicator's "+" button is clicked.
    public var onZoomIn: (() -> Void)?
    /// Called when the inline zoom indicator's "Reset" link is clicked.
    public var onZoomReset: (() -> Void)?

    public override init(frame: NSRect) {
        backButton = Self.makeIconButton(symbol: "chevron.backward",
                                         fallback: "\u{25C0}",
                                         accessibility: "Back")
        forwardButton = Self.makeIconButton(symbol: "chevron.forward",
                                            fallback: "\u{25B6}",
                                            accessibility: "Forward")
        reloadButton = Self.makeIconButton(symbol: "arrow.clockwise",
                                           fallback: "\u{21BB}",
                                           accessibility: "Reload")
        foldButton = Self.makeIconButton(symbol: "arrow.right.and.line.vertical.and.arrow.left",
                                         fallback: "\u{25C4}\u{25BA}",
                                         accessibility: "Fold column")
        zoomOutInlineButton = Self.makeIconButton(symbol: "minus",
                                                  fallback: "-",
                                                  accessibility: "Zoom out")
        zoomInInlineButton = Self.makeIconButton(symbol: "plus",
                                                 fallback: "+",
                                                 accessibility: "Zoom in")
        urlField = NSTextField()

        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor

        setupButtons()
        setupURLField()
        setupZoomIndicator()
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    deinit {
        // `viewDidMoveToWindow` installs a `didResizeNotification`
        // observer on the current window. NotificationCenter stores the
        // observer as an unowned reference, so a zombie dispatch after
        // dealloc would crash. Remove here to match `CommandPaletteView`
        // / `OverlayScrollView`, which use the same pattern.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Icon Button Factory

    private static let iconConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)

    private static func makeIconButton(symbol: String, fallback: String, accessibility: String) -> HoverIconButton {
        let button = HoverIconButton()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
            .withSymbolConfiguration(iconConfig)
        {
            button.image = image
            button.imagePosition = .imageOnly
        } else {
            button.title = fallback
        }
        return button
    }

    // MARK: - Setup

    private func setupButtons() {
        for button in [backButton, forwardButton, reloadButton, foldButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 10)
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        backButton.target = self
        backButton.action = #selector(backAction)
        backButton.toolTip = "Back"
        forwardButton.target = self
        forwardButton.action = #selector(forwardAction)
        forwardButton.toolTip = "Forward"
        reloadButton.target = self
        reloadButton.action = #selector(reloadAction)
        reloadButton.toolTip = "Reload"
        foldButton.target = self
        foldButton.action = #selector(foldAction)
        foldButton.toolTip = "Fold column"

        addSubview(backButton)
        addSubview(forwardButton)
        addSubview(reloadButton)
        addSubview(foldButton)
    }

    private func setupZoomIndicator() {
        zoomPercentLabel.font = .systemFont(ofSize: 11)
        zoomPercentLabel.textColor = .secondaryLabelColor
        zoomPercentLabel.drawsBackground = false
        zoomPercentLabel.isBezeled = false
        zoomPercentLabel.isEditable = false
        zoomPercentLabel.isSelectable = false
        zoomPercentLabel.alignment = .right

        let zoomButtonSize: CGFloat = 22
        for button in [zoomOutInlineButton, zoomInInlineButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 10)
            button.translatesAutoresizingMaskIntoConstraints = false
            // Pin a square hit zone so the entire button — not just the
            // SF Symbol glyph's vector path — responds to hover and
            // clicks. Without an explicit size the intrinsic content
            // size tracks the glyph, leaving the surrounding padding
            // unclaimed by the tracking area and making the `-` / `+`
            // miserable to aim at.
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: zoomButtonSize),
                button.heightAnchor.constraint(equalToConstant: zoomButtonSize),
            ])
        }
        zoomOutInlineButton.target = self
        zoomOutInlineButton.action = #selector(zoomOutInlineAction)
        zoomOutInlineButton.toolTip = "Zoom out"
        zoomInInlineButton.target = self
        zoomInInlineButton.action = #selector(zoomInInlineAction)
        zoomInInlineButton.toolTip = "Zoom in"

        // Text-style reset: transparent bezel, accent-coloured title,
        // pointing-hand cursor from `HoverIconButton`. Using the same
        // subclass as the icon buttons keeps the hit zone = bounds
        // invariant — a plain `NSButton` with `.inline` bezel leaves
        // the cursor as the default arrow and hit zone as just the
        // glyph outline, which reads as non-clickable.
        zoomResetInlineButton.bezelStyle = .inline
        zoomResetInlineButton.isBordered = false
        zoomResetInlineButton.font = .systemFont(ofSize: 11)
        zoomResetInlineButton.translatesAutoresizingMaskIntoConstraints = false
        zoomResetInlineButton.attributedTitle = NSAttributedString(
            string: "Reset",
            attributes: [
                .foregroundColor: NSColor.controlAccentColor,
                .font: NSFont.systemFont(ofSize: 11),
            ]
        )
        zoomResetInlineButton.target = self
        zoomResetInlineButton.action = #selector(zoomResetInlineAction)
        zoomResetInlineButton.toolTip = "Reset zoom"
        // Height matches the icon buttons so the whole cluster sits on
        // a uniform baseline; width tracks the intrinsic "Reset" title
        // plus the corner-radius padding.
        NSLayoutConstraint.activate([
            zoomResetInlineButton.heightAnchor.constraint(equalToConstant: zoomButtonSize),
        ])

        zoomContainer.orientation = .horizontal
        zoomContainer.spacing = 4
        zoomContainer.translatesAutoresizingMaskIntoConstraints = false
        zoomContainer.addArrangedSubview(zoomPercentLabel)
        zoomContainer.addArrangedSubview(zoomOutInlineButton)
        zoomContainer.addArrangedSubview(zoomInInlineButton)
        zoomContainer.addArrangedSubview(zoomResetInlineButton)
        zoomContainer.isHidden = true

        addSubview(zoomContainer)
    }

    private func setupURLField() {
        urlField.placeholderString = "Enter URL or search..."
        urlField.font = .systemFont(ofSize: 12)
        urlField.delegate = self
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.focusRingType = .none
        urlField.cell?.isScrollable = true
        urlField.refusesFirstResponder = true

        addSubview(urlField)
    }

    private func setupLayout() {
        let buttonSize: CGFloat = 22
        let urlToZoom = urlField.trailingAnchor.constraint(
            equalTo: zoomContainer.leadingAnchor, constant: -6
        )
        let urlToFold = urlField.trailingAnchor.constraint(
            equalTo: foldButton.leadingAnchor, constant: -4
        )
        // Default state (zoom == 1.0): zoom indicator hidden, URL field
        // occupies the full trailing slot up to the fold button.
        // `setZoomPercent(_:)` flips these two constraints when a
        // non-default zoom is applied.
        urlToFold.isActive = true
        urlToZoom.isActive = false
        urlTrailingToZoom = urlToZoom
        urlTrailingToFold = urlToFold

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: buttonSize),
            backButton.heightAnchor.constraint(equalToConstant: buttonSize),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: buttonSize),
            forwardButton.heightAnchor.constraint(equalToConstant: buttonSize),

            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 2),
            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.widthAnchor.constraint(equalToConstant: buttonSize),
            reloadButton.heightAnchor.constraint(equalToConstant: buttonSize),

            urlField.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 4),
            urlField.centerYAnchor.constraint(equalTo: centerYAnchor),
            urlField.heightAnchor.constraint(equalToConstant: 22),

            zoomContainer.trailingAnchor.constraint(equalTo: foldButton.leadingAnchor, constant: -4),
            zoomContainer.centerYAnchor.constraint(equalTo: centerYAnchor),

            foldButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            foldButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            foldButton.widthAnchor.constraint(equalToConstant: buttonSize),
            foldButton.heightAnchor.constraint(equalToConstant: buttonSize),
        ])
    }

    // MARK: - Suggestion List Positioning

    /// Position the suggestion list below the URL field using frame-based layout.
    /// Uses window's content view for z-ordering above all pane content.
    private func positionSuggestionList() {
        guard let windowContentView = window?.contentView else { return }

        if suggestionList.superview !== windowContentView {
            suggestionList.removeFromSuperview()
            windowContentView.addSubview(suggestionList)
        }

        // Convert URL field's bottom-left to window content view coordinates
        // AppKit Y=0 is bottom, so fieldFrame.minY is the bottom edge of the field
        let fieldFrame = urlField.convert(urlField.bounds, to: windowContentView)

        suggestionList.frame = NSRect(
            x: fieldFrame.minX,
            y: fieldFrame.minY - suggestionList.frame.height,
            width: fieldFrame.width,
            height: suggestionList.frame.height
        )
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Remove observer for old window, add for new
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowDidResize),
                name: NSWindow.didResizeNotification, object: window
            )
        }
        // Wire up suggestion click handler. The list reports an index into
        // the cell model array — we look up the matching Suggestion in our
        // own backing array before acting on it.
        suggestionList.onSelectIndex = { [weak self] index in
            guard let self, self.currentSuggestions.indices.contains(index) else { return }
            self.acceptSuggestion(self.currentSuggestions[index])
        }
    }

    @objc private func windowDidResize(_ notification: Notification) {
        if !suggestionList.isHidden {
            positionSuggestionList()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        // Click on URL bar's own area (empty space, not subviews)
        onClicked?()
        super.mouseDown(with: event)
    }

    // MARK: - Public API

    /// Update the displayed URL text.
    public func setDisplayURL(_ urlString: String) {
        urlField.stringValue = urlString
    }

    /// Enable/disable back and forward buttons.
    public func setNavigationEnabled(back: Bool, forward: Bool) {
        backButton.isEnabled = back
        forwardButton.isEnabled = forward
    }

    /// Focus the URL field and select all text for quick editing.
    public func focusURLField() {
        urlField.refusesFirstResponder = false
        window?.makeFirstResponder(urlField)
        urlField.selectText(nil)
        urlField.refusesFirstResponder = true
    }

    /// Update the inline zoom indicator to reflect the focused browser
    /// pane's current `pageZoom`. Pass 1.0 to hide the indicator (the
    /// URL field reclaims the trailing space); non-default values
    /// reveal the "NNN% - + Reset" cluster with the rounded percent
    /// filled in.
    public func setZoomPercent(_ zoom: CGFloat) {
        let isAtDefault = abs(zoom - 1.0) < Self.zoomDefaultEpsilon
        zoomContainer.isHidden = isAtDefault
        if isAtDefault {
            urlTrailingToZoom?.isActive = false
            urlTrailingToFold?.isActive = true
        } else {
            urlTrailingToFold?.isActive = false
            urlTrailingToZoom?.isActive = true
            zoomPercentLabel.stringValue = "\(Int(round(zoom * 100)))%"
        }
    }

    // MARK: - Suggestions

    private func acceptSuggestion(_ suggestion: Suggestion) {
        urlField.stringValue = suggestion.url
        suggestionList.dismiss()
        onNavigate?(suggestion.url)
    }

    /// Project a `Suggestion` into the presentation-only model consumed by
    /// `SuggestionListView`. The primary line uses `displayTitle` (which
    /// already prefixes bookmarks with `★`); the URL becomes the secondary
    /// line. No accessory is set for URL-bar suggestions — that slot is
    /// reserved for the command-palette action keyboard shortcuts.
    private static func cellModel(from suggestion: Suggestion) -> SuggestionCellModel {
        SuggestionCellModel(
            primary: suggestion.displayTitle,
            secondary: suggestion.url,
            accessory: nil
        )
    }

    // MARK: - Actions

    @objc private func backAction() {
        onClicked?()
        onBack?()
    }

    @objc private func forwardAction() {
        onClicked?()
        onForward?()
    }

    @objc private func reloadAction() {
        onClicked?()
        onReload?()
    }

    @objc private func foldAction() {
        onClicked?()
        onFold?()
    }

    @objc private func zoomOutInlineAction() {
        onClicked?()
        onZoomOut?()
    }

    @objc private func zoomInInlineAction() {
        onClicked?()
        onZoomIn?()
    }

    @objc private func zoomResetInlineAction() {
        onClicked?()
        onZoomReset?()
    }

    // MARK: - NSTextFieldDelegate

    public func controlTextDidBeginEditing(_ notification: Notification) {
        // User started editing the URL field — treat as pane focus
        onClicked?()
    }

    public func controlTextDidChange(_ notification: Notification) {
        let text = urlField.stringValue
        guard !text.isEmpty else {
            searchDebounceTimer?.invalidate()
            suggestionList.dismiss()
            return
        }
        // Debounce search to avoid SQLite query on every keystroke
        searchDebounceTimer?.invalidate()
        searchDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.searchDebounceInterval, repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let suggestions = self.onTextChanged?(text) ?? []
                self.currentSuggestions = suggestions
                self.suggestionList.update(items: suggestions.map(Self.cellModel(from:)))
                self.positionSuggestionList()
            }
        }
    }

    public func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) {
            if !suggestionList.isHidden,
               let index = suggestionList.selectedIndex,
               currentSuggestions.indices.contains(index) {
                acceptSuggestion(currentSuggestions[index])
            } else {
                onNavigate?(urlField.stringValue)
            }
            suggestionList.dismiss()
            return true
        }
        if selector == #selector(cancelOperation(_:)) {
            suggestionList.dismiss()
            onCancel?()
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
        // Delay dismiss so that a click on the suggestion list can fire
        // handleClick before the list disappears. Without this delay,
        // clicking a suggestion triggers controlTextDidEndEditing (URL
        // field loses focus) → dismiss → list gone → click lost.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // If the new first responder is inside the suggestion list,
            // the user clicked a row — don't dismiss yet; handleClick
            // will dismiss after accepting the selection.
            if let responder = self.window?.firstResponder as? NSView,
               responder.isDescendant(of: self.suggestionList) {
                return
            }
            self.suggestionList.dismiss()
        }
    }
}
