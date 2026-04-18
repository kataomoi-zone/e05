import AppKit

/// Root visual container of the sidebar. Wraps an `NSGlassEffectView`
/// (macOS 26 Tahoe Liquid Glass) whose `contentView` hosts the header,
/// the mode-dependent content area (worklane or per-mode placeholder),
/// and the bottom places section.
///
/// Subviews must be added to `contentView` — adding siblings outside of
/// it carries no z-order guarantee (Apple, WWDC25 session 310). When
/// stage 5 introduces multiple glass panels (per-workspace accent bars),
/// wrap them in `NSGlassEffectContainerView` so AppKit merges them
/// liquidly; stages 1–3 have a single glass so the container would add
/// no value.
///
/// Stage 3-A introduced the mode area: `worklane` is shown for
/// `SidebarMode.tabs`, `placeholder` for the other three modes. Both
/// share the same rect and are toggled via `isHidden`. Stages 3-B /
/// 3-C / 3-D will replace the placeholder with real list views.
@MainActor
final class SidebarOverlayView: NSView {
    let header = SidebarHeaderView()
    let worklane = WorklaneSectionView()
    let placeholder = PlaceholderContentView()
    let places = PlacesSectionView()

    private let glass = NSGlassEffectView()
    private let content = NSView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setupGlass()
        setupContent()
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

    private func setupContent() {
        content.addSubview(header)
        content.addSubview(worklane)
        content.addSubview(placeholder)
        content.addSubview(places)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            // worklane and placeholder occupy the same rect — only one
            // is visible at a time, toggled by the view controller in
            // response to mode changes.
            worklane.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            worklane.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            worklane.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            worklane.bottomAnchor.constraint(lessThanOrEqualTo: places.topAnchor, constant: -8),

            placeholder.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            placeholder.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            placeholder.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            placeholder.bottomAnchor.constraint(equalTo: places.topAnchor, constant: -8),

            places.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            places.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            places.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        // Default state: Tabs mode visible, placeholder hidden. The view
        // controller re-synchronises this on its first `applyMode` call.
        placeholder.isHidden = true
    }
}
