import AppKit

/// Shared URL bar for all pane types. Displays the current address and allows navigation.
/// Toggleable visibility — when hidden, PaneHeaderView serves as fallback notification.
@MainActor
public final class PaneURLBar: NSView, NSTextFieldDelegate {
    public static let barHeight: CGFloat = 28

    private let backButton: NSButton
    private let forwardButton: NSButton
    private let urlField: NSTextField

    /// Called when user submits a URL (presses Enter).
    public var onNavigate: ((String) -> Void)?
    /// Called when user clicks back button.
    public var onBack: (() -> Void)?
    /// Called when user clicks forward button.
    public var onForward: (() -> Void)?
    /// Called when user presses ESC to dismiss URL field.
    public var onCancel: (() -> Void)?

    public override init(frame: NSRect) {
        backButton = NSButton(title: "\u{25C0}", target: nil, action: nil)
        forwardButton = NSButton(title: "\u{25B6}", target: nil, action: nil)
        urlField = NSTextField()

        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.12, alpha: 1.0).cgColor

        setupButtons()
        setupURLField()
        setupLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    // MARK: - Setup

    private func setupButtons() {
        for button in [backButton, forwardButton] {
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        backButton.target = self
        backButton.action = #selector(backAction)
        forwardButton.target = self
        forwardButton.action = #selector(forwardAction)

        addSubview(backButton)
        addSubview(forwardButton)
    }

    private func setupURLField() {
        urlField.placeholderString = "Enter URL or e05://terminal..."
        urlField.font = .systemFont(ofSize: 12)
        urlField.delegate = self
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.focusRingType = .none
        urlField.cell?.isScrollable = true
        urlField.refusesFirstResponder = true

        addSubview(urlField)
    }

    private func setupLayout() {
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 24),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 24),

            urlField.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 4),
            urlField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            urlField.centerYAnchor.constraint(equalTo: centerYAnchor),
            urlField.heightAnchor.constraint(equalToConstant: 22),
        ])
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

    // MARK: - Actions

    @objc private func backAction() {
        onBack?()
    }

    @objc private func forwardAction() {
        onForward?()
    }

    // MARK: - NSTextFieldDelegate

    public func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) {
            onNavigate?(urlField.stringValue)
            return true
        }
        if selector == #selector(cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}
