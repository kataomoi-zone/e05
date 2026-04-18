import AppKit

/// Root visual container of the sidebar. Wraps an `NSGlassEffectView`
/// (macOS 26 Tahoe Liquid Glass) whose `contentView` hosts the stage-1
/// header. Future stages fill the middle and bottom regions with the
/// worklane tree and places sections.
///
/// Subviews must be added to `contentView` — adding siblings outside of
/// it carries no z-order guarantee (Apple, WWDC25 session 310). When
/// stage 5 introduces multiple glass panels (per-workspace accent bars),
/// wrap them in `NSGlassEffectContainerView` so AppKit merges them
/// liquidly; stage 1 has a single glass so the container would add no
/// value.
@MainActor
final class SidebarOverlayView: NSView {
    let header = SidebarHeaderView()

    private let glass = NSGlassEffectView()
    private let content = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setupGlass()
        setupHeader()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func setupGlass() {
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        // NSGlassEffectView attaches its `contentView` lazily: right after
        // assignment `content.superview` is still nil; AppKit wires it in
        // during the first layout pass (observed on macOS 26 Tahoe beta).
        // Trust the Apple docs' Auto Layout guarantee and let the layout
        // cycle run — manual testing confirms header renders correctly
        // without explicit pinning.
        glass.contentView = content
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupHeader() {
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }
}
