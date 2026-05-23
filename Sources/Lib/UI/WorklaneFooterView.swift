import AppKit

/// Sticky footer pinned below the worklane outline view. Hosts
/// two buttons — plain `+` (New Workspace) and dashed `+` (New
/// Private Workspace) — so the workspace-creation entry points
/// live inside the worklane mode where they make sense without
/// taking up screen space inside any single workspace's row group
/// (`createWorkspace` always appends, so a single bottom-of-list
/// affordance is all we need).
@MainActor
final class WorklaneFooterView: NSView {
  /// 28pt matches the workspace header row's rhythm — the footer
  /// reads as a sibling chrome strip rather than another workspace.
  static let height: CGFloat = 28

  private let addButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "plus", accessibilityDescription: "New workspace")
    b.toolTip = "New Workspace"
    return b
  }()

  private let addPrivateButton: HoverIconButton = {
    let b = HoverIconButton()
    b.translatesAutoresizingMaskIntoConstraints = false
    b.isBordered = false
    b.bezelStyle = .regularSquare
    b.imagePosition = .imageOnly
    b.imageScaling = .scaleProportionallyDown
    b.image = NSImage(
      systemSymbolName: "plus.circle.dashed",
      accessibilityDescription: "New private workspace")
    b.toolTip = "New Private Workspace"
    return b
  }()

  private var onCreateWorkspaceHandler: (() -> Void)?
  private var onCreatePrivateHandler: (() -> Void)?

  init() {
    super.init(frame: .zero)
    setupLayout()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError() }

  private func setupLayout() {
    wantsLayer = true
    addButton.target = self
    addButton.action = #selector(addTapped(_:))
    addPrivateButton.target = self
    addPrivateButton.action = #selector(addPrivateTapped(_:))

    // Footer buttons stay visible without hover-to-reveal. The
    // strip is a dedicated control surface (no other content
    // competing) so reveal-gating the icons would just slow the
    // user down.
    addButton.setRevealed(true)
    addPrivateButton.setRevealed(true)

    addSubview(addButton)
    addSubview(addPrivateButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: Self.height),
      // Align with the workspace-row leading edge so the strip
      // visually belongs to the worklane content rather than the
      // outline view's gutter.
      addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      addButton.widthAnchor.constraint(equalToConstant: 18),
      addButton.heightAnchor.constraint(equalToConstant: 18),

      addPrivateButton.leadingAnchor.constraint(
        equalTo: addButton.trailingAnchor, constant: 6),
      addPrivateButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      addPrivateButton.widthAnchor.constraint(equalToConstant: 18),
      addPrivateButton.heightAnchor.constraint(equalToConstant: 18),
    ])
  }

  func configure(input: WorklaneSectionView.ReloadInput) {
    onCreateWorkspaceHandler = { [onCreate = input.onCreateWorkspace] in onCreate() }
    onCreatePrivateHandler = {
      [onCreatePrivate = input.onCreatePrivateWorkspace] in onCreatePrivate()
    }
  }

  @objc private func addTapped(_: NSButton) {
    onCreateWorkspaceHandler?()
  }

  @objc private func addPrivateTapped(_: NSButton) {
    onCreatePrivateHandler?()
  }

  override func resetCursorRects() {
    addCursorRect(addButton.frame, cursor: .pointingHand)
    addCursorRect(addPrivateButton.frame, cursor: .pointingHand)
  }
}
