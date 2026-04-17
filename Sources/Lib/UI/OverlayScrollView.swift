import AppKit

/// NSScrollView that forces overlay scrollers regardless of system preference.
/// Overrides the getter to always return .overlay, and re-applies on system
/// preference changes (e.g. mouse connect/disconnect).
final class OverlayScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollerStyleDidChange),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    @objc private func scrollerStyleDidChange(_ notification: Notification) {
        super.scrollerStyle = .overlay
    }
}
