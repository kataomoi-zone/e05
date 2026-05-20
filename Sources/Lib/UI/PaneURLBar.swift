import AppKit

/// Shared URL bar for all pane types. Displays the current address and allows navigation.
/// Toggleable visibility — when hidden, PaneHeaderView serves as fallback notification.
@MainActor
public final class PaneURLBar: NSView, NSTextFieldDelegate, NSMenuDelegate {
  public static let barHeight: CGFloat = 28

  private let backButton: HoverIconButton
  private let forwardButton: HoverIconButton
  let reloadButton: HoverIconButton
  /// Speaker affordance shown only while the page has active media
  /// playback or is currently muted. Click toggles the pane's mute
  /// flag. Sized identically to the navigation buttons so the row's
  /// vertical centering stays even.
  private let muteButton: HoverIconButton
  private let foldButton: HoverIconButton
  private let urlField: NSTextField
  private let suggestionList = SuggestionListView(useGlass: true)
  /// Child NSPanel that hosts `suggestionList`. AppKit's
  /// NSTrackingArea machinery is not z-order aware, so a same-window
  /// dropdown lets the WKWebView underneath keep firing hover events
  /// (CSS `:hover`) even while the dropdown is on top. Lifting the
  /// list into a child window makes hover / click routing bypass the
  /// main window's contentView entirely — the WebView stops seeing
  /// cursor traffic the moment the panel is ordered front. Mirrors
  /// how Safari / Spotlight implement their popups.
  ///
  /// `nonactivatingPanel` keeps first responder on the URL field so
  /// the user can keep typing after the panel appears; `popUpMenu`
  /// level sits above ordinary windows; `transient` collection
  /// behavior keeps the panel out of Mission Control / window cycle.
  /// Created lazily on first show so panes that never present a
  /// dropdown don't pay the allocation.
  private var suggestionPanel: NSPanel?

  /// Animatable leading offset that shifts the suggestion list inside
  /// the panel's clipping wrapper. When the URL field is partially
  /// clipped by the host window's leading edge, this constant goes
  /// negative so the list extends behind the wrapper's left edge —
  /// matching `FindBarView.cardLeadingConstraint` (lessons.md
  /// "Anchored content with clipping"). Zero when the field is fully
  /// visible.
  private weak var suggestionListLeadingConstraint: NSLayoutConstraint?
  /// Width constraint on the suggestion list inside the wrapper. Set
  /// to the URL field's natural on-screen width so cells render at
  /// the field's full width regardless of how narrow the visible
  /// panel slice becomes; the wrapper's `masksToBounds` clip cuts
  /// off the off-window portion. Updated in `positionSuggestionList`
  /// alongside the leading offset.
  private weak var suggestionListWidthConstraint: NSLayoutConstraint?
  /// Clipping wrapper hosting `suggestionList` inside the dropdown
  /// panel. Held weakly so `positionSuggestionList` can flip the
  /// wrapper's `maskedCorners` to square off whichever side is
  /// hidden behind the window edge — preserving the "the dropdown
  /// continues past the screen" affordance instead of rounding the
  /// clipped edge as if the dropdown ended there.
  private weak var suggestionWrapperView: NSView?

  /// Observer token for the workspace's clipView bounds notifications.
  /// The panel sits in screen coordinates, so when the user scrolls
  /// the workspace horizontally the URL field slides under the panel
  /// without the panel following. Re-running `positionSuggestionList`
  /// on every clipView bounds change keeps the panel anchored to the
  /// field's current screen rect.
  ///
  /// `nonisolated(unsafe)` so `deinit` can read it under Swift 6
  /// strict concurrency. `NSObjectProtocol` does not conform to
  /// Sendable, but the value is only mutated on MainActor and only
  /// read by the deinit handoff to NotificationCenter — the same
  /// pattern as `BookmarksSidebarView.scrollObserver`.
  nonisolated(unsafe) private var scrollObserver: NSObjectProtocol?
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

  /// Toolbar row for enabled web extensions, rebuilt from
  /// `ExtensionController.loadedExtensions` whenever the controller
  /// posts `didChangeNotification`. Placed between the URL field's
  /// trailing edge and the zoom indicator (or the fold button when
  /// zoom is hidden) so extensions sit at the right of the address,
  /// matching Chrome / Safari conventions.
  let extensionsContainer = NSStackView()
  /// `extensionsContainer.trailing == zoomContainer.leading - 6`.
  /// Active when the zoom indicator is visible.
  var extensionsTrailingToZoom: NSLayoutConstraint?
  /// `extensionsContainer.trailing == foldButton.leading - 4`.
  /// Active in the default (zoom hidden) layout.
  var extensionsTrailingToFold: NSLayoutConstraint?
  /// Per-extension toolbar buttons keyed by source URL so click
  /// handlers can recover the model identity without parsing the
  /// button's identifier or rebuilding the lookup on every event.
  private var extensionButtons: [URL: HoverIconButton] = [:]
  /// Whether the extension action row should rebuild on
  /// `didChangeNotification`. Browser panes display extension
  /// actions; terminal / finder / settings panes never run
  /// extensions, so showing the row there only adds visual noise
  /// and steals horizontal space from the URL field. The host
  /// flips this once per pane right after init.
  public var showsExtensionsRow: Bool = true {
    didSet {
      guard oldValue != showsExtensionsRow else { return }
      reloadExtensions()
    }
  }
  /// Subscription to `ExtensionController.didChangeNotification`.
  /// `nonisolated(unsafe)` mirrors the existing `Bookmarks` /
  /// `History` sidebar observer pattern — block-based observers
  /// retain their closure inside NotificationCenter, so the token
  /// is removed in `deinit`.
  nonisolated(unsafe) private var extensionsObserver: NSObjectProtocol?

  /// Keeps the dropdown clipping wrapper's corner radius in sync
  /// with `AppMetrics.surfaceCornerRadius`. Recreated each time the
  /// dropdown is rebuilt; the previous observer's deinit removes
  /// the listener it registered.
  private var dropdownCornerObserver: SurfaceCornerObserver?

  /// Whether the reload button currently shows the stop affordance.
  /// Owned by `setReloadButtonLoading(_:)` so the click handler can
  /// dispatch to either `onReload` or `onStop` without consulting
  /// the image/title, which are view-layer details.
  private(set) var isReloadLoading: Bool = false

  /// `urlField.leading == reloadButton.trailing + 4`. Active when
  /// the mute button is hidden, so the URL field hugs the reload
  /// button without leaving a gap.
  private var urlFieldLeadingToReload: NSLayoutConstraint?
  /// `urlField.leading == muteButton.trailing + 4`. Active when the
  /// mute button is visible, so the URL field shifts right to make
  /// room.
  private var urlFieldLeadingToMute: NSLayoutConstraint?

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
  /// Called when user clicks the stop button (the reload icon flips
  /// to an `xmark` while the page is loading).
  public var onStop: (() -> Void)?
  /// Called when the user clicks the speaker affordance to toggle
  /// the pane's mute flag.
  public var onMuteToggle: (() -> Void)?
  /// Called when the user picks "Mute this Site" / "Unmute this Site"
  /// from the speaker's right-click menu. The host string is the
  /// fully-qualified host of the URL the bar last displayed; the
  /// caller decides whether to add or remove the entry.
  public var onMuteSiteToggle: ((String) -> Void)?

  /// Host of the URL most recently passed to `setDisplayURL`,
  /// captured for the speaker's right-click "Mute this Site" menu.
  /// The URL bar is single-source-of-truth for what the user sees;
  /// pulling the host from here (rather than `webView.url`) keeps
  /// the menu's site reference aligned with the displayed string.
  ///
  /// `setDisplayURL` is only called by the host pane with model-
  /// derived URL strings, never with raw field-editor input or
  /// suggestion previews, so `currentHost` cannot drift to text the
  /// user is typing. A non-URL display string (e.g. an `e05://`
  /// internal scheme without a host) collapses `currentHost` to
  /// `nil` and `menuNeedsUpdate(_:)` builds an empty menu — no
  /// stale-host risk.
  private var currentHost: String?
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
  /// Called when the user picks `Open Options Page` from a pinned
  /// extension's right-click menu or the puzzle popover. Routed
  /// through a separate callback (rather than reusing `onNavigate`,
  /// which would replace the current pane's content) so the host
  /// can lift it into a fresh column the way the sidebar does.
  public var onOpenURLInNewColumn: ((URL) -> Void)?
  /// Called when the user accepts a suggestion whose URL is already
  /// open in another pane. The host focuses that pane (cross-WS if
  /// needed) instead of triggering a duplicate navigation.
  public var onSwitchToPane: ((ULID) -> Void)?

  /// Cursor entered the URL bar's bounds. The hover scheduler in
  /// `PaneContainerViewController` uses this to keep a peek alive
  /// while the user is hovering the bar itself, not just the
  /// 12pt edge hit zone above it.
  public var onHoverEnter: (() -> Void)?
  /// Cursor left the URL bar's bounds. Pairs with `onHoverEnter`
  /// to extend hover-out scheduling across the whole bar.
  public var onHoverExit: (() -> Void)?

  /// The field editor detached and the cursor is no longer inside
  /// the bar's bounds. The host uses this to collapse a `.peek`
  /// reveal immediately rather than running another 300ms hover-out
  /// debounce — once the user has finished typing and moved away,
  /// there's nothing the bar should be waiting for.
  public var onEditingEndedOutsideBar: (() -> Void)?

  /// Whether the URL field is currently being edited. The hover-out
  /// scheduler reads this to defer collapse while a field editor is
  /// attached — letting the bar disappear mid-type would dismiss the
  /// suggestion list and lose whatever the user just typed.
  public var isEditing: Bool { urlField.currentEditor() != nil }

  private var hoverTrackingArea: NSTrackingArea?

  public override init(frame: NSRect) {
    backButton = Self.makeIconButton(
      symbol: "chevron.backward",
      fallback: "\u{25C0}",
      accessibility: "Back")
    forwardButton = Self.makeIconButton(
      symbol: "chevron.forward",
      fallback: "\u{25B6}",
      accessibility: "Forward")
    reloadButton = Self.makeIconButton(
      symbol: "arrow.clockwise",
      fallback: "\u{21BB}",
      accessibility: "Reload")
    muteButton = Self.makeIconButton(
      symbol: "speaker.wave.2.fill",
      fallback: "\u{1F50A}",
      accessibility: "Toggle mute")
    foldButton = Self.makeIconButton(
      symbol: "arrow.right.and.line.vertical.and.arrow.left",
      fallback: "\u{25C4}\u{25BA}",
      accessibility: "Fold column")
    zoomOutInlineButton = Self.makeIconButton(
      symbol: "minus",
      fallback: "-",
      accessibility: "Zoom out")
    zoomInInlineButton = Self.makeIconButton(
      symbol: "plus",
      fallback: "+",
      accessibility: "Zoom in")
    urlField = NSTextField()

    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = AppColors.popoverSurface.cgColor

    setupButtons()
    setupURLField()
    setupZoomIndicator()
    setupExtensionsContainer()
    setupLayout()
  }

  public override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AppColors.popoverSurface.cgColor
    }
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
    // The extensions observer is the block-based form, which keeps
    // its closure alive inside NotificationCenter until the token
    // is removed explicitly.
    if let token = extensionsObserver {
      NotificationCenter.default.removeObserver(token)
    }
    if let token = scrollObserver {
      NotificationCenter.default.removeObserver(token)
    }
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
    for button in [backButton, forwardButton, reloadButton, muteButton, foldButton] {
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
    muteButton.target = self
    muteButton.action = #selector(muteAction)
    muteButton.toolTip = "Mute pane"
    muteButton.isHidden = true
    // Right-click on the speaker opens a context menu with the
    // persistent "Mute this Site" toggle. The menu's items are
    // rebuilt in `menuNeedsUpdate(_:)` against the current host so
    // the label flips between Mute / Unmute without keeping a
    // separate cache.
    let muteContextMenu = NSMenu()
    muteContextMenu.delegate = self
    muteButton.menu = muteContextMenu
    foldButton.target = self
    foldButton.action = #selector(foldAction)
    foldButton.toolTip = "Fold column"

    addSubview(backButton)
    addSubview(forwardButton)
    addSubview(reloadButton)
    addSubview(muteButton)
    addSubview(foldButton)
  }

  private func setupExtensionsContainer() {
    extensionsContainer.orientation = .horizontal
    extensionsContainer.spacing = 2
    extensionsContainer.translatesAutoresizingMaskIntoConstraints = false
    addSubview(extensionsContainer)

    // Subscribe to controller-side state changes so install /
    // remove / forget / toggle / Web Store install all reflect in
    // the toolbar without an explicit reload from the call site.
    extensionsObserver = NotificationCenter.default.addObserver(
      forName: ExtensionController.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reloadExtensions() }
    }
    reloadExtensions()
  }

  /// Rebuild the toolbar's extension button row from the controller's
  /// snapshot. Pinned extensions take a permanent button slot;
  /// every other enabled extension lives behind a puzzle-piece menu
  /// at the trailing edge of the row, matching Chrome's split. The
  /// puzzle button only appears when at least one unpinned enabled
  /// extension exists, so a fully pinned setup keeps the row clean.
  /// Buttons are rebuilt rather than diff-applied because the row is
  /// bounded by the user's installed extension count and rebuilding
  /// is simpler than tracking stable identity across NSStackView
  /// arranged subviews.
  private func reloadExtensions() {
    for view in extensionsContainer.arrangedSubviews {
      view.removeFromSuperview()
    }
    extensionButtons.removeAll()
    // Non-browser panes never trigger extension actions, so the
    // row stays empty and the URL field reclaims the horizontal
    // space the row would otherwise occupy.
    guard showsExtensionsRow else { return }

    let enabledEntries = ExtensionController.shared.loadedExtensions.filter { $0.isEnabled }
    for entry in enabledEntries where entry.isPinned {
      let button = makeExtensionActionButton(for: entry)
      extensionsContainer.addArrangedSubview(button)
      extensionButtons[entry.sourceURL] = button
    }
    let hasUnpinned = enabledEntries.contains { !$0.isPinned }
    if hasUnpinned {
      extensionsContainer.addArrangedSubview(makePuzzleMenuButton())
    }
  }

  /// Action-row button for a single pinned extension. Click triggers
  /// `performAction` (popup popover), right-click surfaces a per-row
  /// context menu so the user can unpin or open the options page
  /// without opening the sidebar.
  private func makeExtensionActionButton(for entry: LoadedExtension) -> HoverIconButton {
    let button = HoverIconButton()
    let iconSize = NSSize(width: 16, height: 16)
    // Prefer the action icon (toolbar/badge surface) and fall back
    // to the extension's manifest icon — same precedence the
    // sidebar list uses, just at a smaller size.
    let actionIcon = ExtensionController.shared.defaultAction(for: entry.sourceURL)?
      .icon(for: iconSize)
    button.image = actionIcon ?? entry.icon
    button.imagePosition = .imageOnly
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = .systemFont(ofSize: 10)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.toolTip = entry.displayName
    button.target = self
    button.action = #selector(extensionAction(_:))
    button.menu = makePinnedContextMenu(for: entry)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.extensionButtonSize),
      button.heightAnchor.constraint(equalToConstant: Self.extensionButtonSize),
    ])
    return button
  }

  /// Persistent puzzle-piece glyph that gathers every unpinned
  /// enabled extension into a popped-up menu. `Extensions` toolTip
  /// matches Safari / Chrome wording so the icon is recognisable
  /// even at the small inline size.
  private func makePuzzleMenuButton() -> HoverIconButton {
    let button = HoverIconButton()
    button.image = NSImage(
      systemSymbolName: "puzzlepiece.extension",
      accessibilityDescription: "Extensions"
    )
    button.imagePosition = .imageOnly
    button.bezelStyle = .inline
    button.isBordered = false
    button.font = .systemFont(ofSize: 10)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.toolTip = "Extensions"
    button.target = self
    button.action = #selector(showPuzzleMenu(_:))
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.extensionButtonSize),
      button.heightAnchor.constraint(equalToConstant: Self.extensionButtonSize),
    ])
    return button
  }

  /// Per-button context menu for pinned extensions. Built fresh on
  /// each rebuild so the captured `sourceURL` always tracks the
  /// snapshot row.
  private func makePinnedContextMenu(for entry: LoadedExtension) -> NSMenu {
    let menu = NSMenu()
    let unpin = NSMenuItem(
      title: "Unpin from URL Bar",
      action: #selector(menuUnpin(_:)),
      keyEquivalent: ""
    )
    unpin.target = self
    unpin.image = NSImage(systemSymbolName: "pin.slash", accessibilityDescription: nil)
    unpin.representedObject = entry.sourceURL
    menu.addItem(unpin)
    let optionsURL = ExtensionController.shared.optionsPageURL(for: entry.sourceURL)
    let options = NSMenuItem(
      title: "Open Options Page",
      action: #selector(menuOpenOptions(_:)),
      keyEquivalent: ""
    )
    options.target = self
    options.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    options.representedObject = entry.sourceURL
    options.isEnabled = optionsURL != nil
    menu.addItem(options)
    return menu
  }

  /// Diameter of the pinned-action / puzzle buttons. Matches the
  /// existing zoom-indicator buttons so the row reads as a single
  /// rhythm of 22pt squares.
  private static let extensionButtonSize: CGFloat = 22

  @objc private func extensionAction(_ sender: NSButton) {
    // Reverse-lookup keeps the URL out of the button's identifier
    // (which doesn't round-trip arbitrary URLs cleanly) at the cost
    // of an O(n) walk; n is bounded by pinned-extension count.
    guard let entry = extensionButtons.first(where: { $0.value === sender })
    else { return }
    let sourceURL = entry.key
    ExtensionController.shared.performAction(
      for: sourceURL, anchorView: sender, anchorRect: sender.bounds
    )
  }

  @objc private func showPuzzleMenu(_ sender: NSButton) {
    let menu = NSMenu()
    let unpinned = ExtensionController.shared.loadedExtensions
      .filter { $0.isEnabled && !$0.isPinned }
    if unpinned.isEmpty {
      // Defensive: the puzzle button only renders when this list is
      // non-empty, but a `didChangeNotification` arriving between
      // build and click could leave the button referencing a now-
      // empty set. Show a disabled placeholder so the menu still
      // pops (instead of swallowing the click silently).
      let item = NSMenuItem(title: "No extensions to show", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    } else {
      let iconSize = NSSize(width: 16, height: 16)
      for entry in unpinned {
        let actionIcon = ExtensionController.shared.defaultAction(for: entry.sourceURL)?
          .icon(for: iconSize)
        let item = NSMenuItem(
          title: entry.displayName,
          action: #selector(puzzleMenuPick(_:)),
          keyEquivalent: ""
        )
        item.target = self
        item.image = actionIcon ?? entry.icon
        item.representedObject = entry.sourceURL
        // Sub-menu carries pin / options actions; the main click
        // still fires the extension popup so the menu reads as a
        // shortcut for the pinned-row click.
        item.submenu = makeUnpinnedSubmenu(for: entry)
        menu.addItem(item)
      }
    }
    let origin = NSPoint(x: 0, y: sender.bounds.height)
    menu.popUp(positioning: nil, at: origin, in: sender)
  }

  private func makeUnpinnedSubmenu(for entry: LoadedExtension) -> NSMenu {
    let submenu = NSMenu()
    let pin = NSMenuItem(
      title: "Pin to URL Bar",
      action: #selector(menuPin(_:)),
      keyEquivalent: ""
    )
    pin.target = self
    pin.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
    pin.representedObject = entry.sourceURL
    submenu.addItem(pin)
    let optionsURL = ExtensionController.shared.optionsPageURL(for: entry.sourceURL)
    let options = NSMenuItem(
      title: "Open Options Page",
      action: #selector(menuOpenOptions(_:)),
      keyEquivalent: ""
    )
    options.target = self
    options.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    options.representedObject = entry.sourceURL
    options.isEnabled = optionsURL != nil
    submenu.addItem(options)
    return submenu
  }

  @objc private func puzzleMenuPick(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    // Anchor the popup against the puzzle button itself: the menu's
    // host view is the URL bar, but the visible glyph for unpinned
    // extensions is the puzzle button so the popup arrow lands on
    // a recognisable target. The puzzle button is always the trailing
    // arranged subview when this menu is reachable — `reloadExtensions`
    // appends it after every pinned button and only when at least one
    // unpinned extension exists, so `.last` is the puzzle whenever
    // `puzzleMenuPick` can possibly fire.
    let puzzle = extensionsContainer.arrangedSubviews.last
    ExtensionController.shared.performAction(
      for: url,
      anchorView: puzzle ?? self,
      anchorRect: puzzle?.bounds ?? .zero
    )
  }

  @objc private func menuPin(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    ExtensionController.shared.setPinned(true, for: url)
  }

  @objc private func menuUnpin(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    ExtensionController.shared.setPinned(false, for: url)
  }

  @objc private func menuOpenOptions(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL,
      let optionsURL = ExtensionController.shared.optionsPageURL(for: url)
    else { return }
    onOpenURLInNewColumn?(optionsURL)
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

    // Text-style reset: transparent bezel, neutral title colour to
    // match the neighbouring `121% − +` cluster (percent label uses
    // secondaryLabelColor, the icon buttons render SF Symbols with
    // the same default template tint). The earlier controlAccentColor
    // fill looked like a misplaced hyperlink on dark aqua and hit
    // the WCAG AA contrast boundary with graphite / gray accents.
    // Pointing-hand cursor from `HoverIconButton` still signals
    // clickability.
    zoomResetInlineButton.bezelStyle = .inline
    zoomResetInlineButton.isBordered = false
    zoomResetInlineButton.font = .systemFont(ofSize: 11)
    zoomResetInlineButton.translatesAutoresizingMaskIntoConstraints = false
    zoomResetInlineButton.attributedTitle = NSAttributedString(
      string: "Reset",
      attributes: [
        .foregroundColor: NSColor.secondaryLabelColor,
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
      zoomResetInlineButton.heightAnchor.constraint(equalToConstant: zoomButtonSize)
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
    // URL field's trailing edge anchors to the extensions container,
    // which in turn anchors to either the zoom indicator (when
    // visible) or the fold button. The dual-constraint switch lives
    // on the extensions container, not the URL field, so the field's
    // trailing edge stays put as zoom toggles — only the extensions
    // row shifts.
    let extToZoom = extensionsContainer.trailingAnchor.constraint(
      equalTo: zoomContainer.leadingAnchor, constant: -6
    )
    let extToFold = extensionsContainer.trailingAnchor.constraint(
      equalTo: foldButton.leadingAnchor, constant: -4
    )
    extToFold.isActive = true
    extToZoom.isActive = false
    extensionsTrailingToZoom = extToZoom
    extensionsTrailingToFold = extToFold

    // The URL field anchors to the mute button when the speaker
    // affordance is visible and snaps back to the reload button when
    // it's hidden — the field reclaims the space rather than leaving
    // a gap, matching how the zoom indicator's dual-constraint switch
    // governs the extensions container.
    let urlToReload = urlField.leadingAnchor.constraint(
      equalTo: reloadButton.trailingAnchor, constant: 4
    )
    let urlToMute = urlField.leadingAnchor.constraint(
      equalTo: muteButton.trailingAnchor, constant: 4
    )
    urlToReload.isActive = true
    urlToMute.isActive = false
    urlFieldLeadingToReload = urlToReload
    urlFieldLeadingToMute = urlToMute

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

      muteButton.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 2),
      muteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      muteButton.widthAnchor.constraint(equalToConstant: buttonSize),
      muteButton.heightAnchor.constraint(equalToConstant: buttonSize),

      urlField.trailingAnchor.constraint(
        equalTo: extensionsContainer.leadingAnchor, constant: -6
      ),
      urlField.centerYAnchor.constraint(equalTo: centerYAnchor),
      urlField.heightAnchor.constraint(equalToConstant: 22),

      extensionsContainer.centerYAnchor.constraint(equalTo: centerYAnchor),

      zoomContainer.trailingAnchor.constraint(equalTo: foldButton.leadingAnchor, constant: -4),
      zoomContainer.centerYAnchor.constraint(equalTo: centerYAnchor),

      foldButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
      foldButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      foldButton.widthAnchor.constraint(equalToConstant: buttonSize),
      foldButton.heightAnchor.constraint(equalToConstant: buttonSize),
    ])
  }

  // MARK: - Suggestion List Positioning

  /// Build (or reattach) the child NSPanel that hosts the suggestion
  /// list. Idempotent: subsequent calls return the existing panel and
  /// re-parent it if the URL bar has migrated to a different host
  /// window (single-window-app invariant currently rules this out, but
  /// the guard is cheap insurance against future multi-window changes).
  private func ensureSuggestionPanel(parentWindow: NSWindow) -> NSPanel {
    if let panel = suggestionPanel {
      if panel.parent !== parentWindow {
        panel.parent?.removeChildWindow(panel)
        parentWindow.addChildWindow(panel, ordered: .above)
      }
      return panel
    }
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )

    // Wrap the suggestion list in a clipping container that owns the
    // rounded-corner clip and the visible-width adjustments. The
    // suggestion list itself stays at the URL field's natural width
    // (driven by `suggestionListWidthConstraint`) so cells render
    // full-width regardless of how narrow the visible panel slice
    // becomes — the wrapper's `masksToBounds` cuts off the off-window
    // portion. Same pattern as `FindBarView.glass.contentView = inner`
    // + fixed `card` (lessons.md "Anchored content with clipping").
    // Truncate-within-cell was the prior path, but at the field's
    // far-edge positions the visible slice is too narrow for any text
    // to read anyway, so clipping at the panel boundary looks cleaner
    // without losing information that wasn't already lost.
    let wrapper = NSView()
    wrapper.wantsLayer = true
    wrapper.layer?.cornerCurve = .continuous
    wrapper.layer?.masksToBounds = true
    // NSWindow auto-resizes its contentView via the autoresizing
    // path on every `setFrame`; opt in explicitly so the wrapper's
    // bounds stay locked to `panel.contentLayoutRect` whenever
    // `positionSuggestionList` reframes the panel.
    wrapper.autoresizingMask = [.width, .height]
    dropdownCornerObserver = SurfaceCornerObserver(applyingTo: wrapper)
    panel.contentView = wrapper

    suggestionList.translatesAutoresizingMaskIntoConstraints = false
    wrapper.addSubview(suggestionList)
    let leading = suggestionList.leadingAnchor.constraint(
      equalTo: wrapper.leadingAnchor)
    // Width starts at 0 as a sentinel; `positionSuggestionList`
    // overrides it with `fieldOnScreen.width` before the panel is
    // ever ordered front, so the zero never reaches a layout pass
    // that would render a 0pt-wide list.
    let width = suggestionList.widthAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      leading,
      width,
      suggestionList.topAnchor.constraint(equalTo: wrapper.topAnchor),
      suggestionList.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
    ])
    suggestionListLeadingConstraint = leading
    suggestionListWidthConstraint = width
    suggestionWrapperView = wrapper

    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .popUpMenu
    panel.hidesOnDeactivate = true
    panel.collectionBehavior = [.transient, .ignoresCycle]
    panel.acceptsMouseMovedEvents = true
    // The panel is owned through `suggestionPanel` and via the parent's
    // child-window retain. Disabling the implicit close-then-release
    // path avoids the double-release crash if AppKit ever closes the
    // panel from a path we don't drive (e.g. parent close while we
    // still hold the reference).
    panel.isReleasedWhenClosed = false
    parentWindow.addChildWindow(panel, ordered: .above)
    suggestionPanel = panel
    return panel
  }

  /// Position the suggestion panel directly below the URL field and
  /// drive its visibility from `suggestionList.isHidden`. The list's
  /// own `update(items:)` is the source of truth for whether anything
  /// is worth showing — empty results hide the list, populated results
  /// reveal it — so this method just translates that flag into the
  /// panel's `orderFront` / `orderOut` lifecycle.
  private func positionSuggestionList() {
    if suggestionList.isHidden {
      suggestionPanel?.orderOut(nil)
      return
    }
    guard let mainWindow = window else { return }

    // The suggestion list is constraint-driven inside the wrapper
    // (its frame tracks the wrapper's height and the natural-width
    // constraint), so `frame.size.height` doesn't carry the value
    // that `update(items:)` just computed. Pull from
    // `intrinsicContentSize` instead — that returns the same
    // `contentHeight` the list assigns to its frame internally.
    let listHeight = suggestionList.intrinsicContentSize.height

    let panel = ensureSuggestionPanel(parentWindow: mainWindow)

    // Anchor the panel to the URL field's bottom edge in screen
    // coordinates. AppKit screen Y is bottom-up, so subtracting the
    // panel height from `fieldOnScreen.minY` puts the panel just below
    // the field visually (same outcome as the prior windowContentView
    // path, just routed through screen space because child windows
    // live there).
    let fieldInWindow = urlField.convert(urlField.bounds, to: nil)
    let fieldOnScreen = mainWindow.convertToScreen(fieldInWindow)

    // Clip the URL field's screen rect to the host window's frame.
    // The URL field can sit partly (or wholly) outside the window
    // when the user scrolls the workspace far enough that the field's
    // pane is past either edge. A child window doesn't inherit the
    // parent contentView's clipping, so without this clip the panel
    // can render past the window — fully off-screen on hard scrolls,
    // or as a thin vertical sliver when only a few pixels of field
    // peek over the edge. The Liquid Glass blur in those positions
    // also picks up undefined off-screen sample sources, which shows
    // up as the dropdown turning white when the field eventually
    // scrolls back. Clipping to the window bounds keeps the panel
    // anchored to whatever portion of the field is actually visible.
    let windowFrame = mainWindow.frame
    let visibleLeft = max(fieldOnScreen.minX, windowFrame.minX)
    let visibleRight = min(fieldOnScreen.maxX, windowFrame.maxX)
    let visibleWidth = max(0, visibleRight - visibleLeft)

    // If the field is essentially clipped away, hide the panel
    // outright. Showing a 20pt-wide dropdown over the last visible
    // sliver is unreadable and the partial render would push past
    // the clamp anyway. The threshold is intentionally loose so that
    // even a half-clipped field still gets a useful (if narrow)
    // dropdown rather than vanishing on the slightest overscroll.
    let minVisibleWidth: CGFloat = 80
    if visibleWidth < minVisibleWidth {
      panel.orderOut(nil)
      return
    }

    // Suggestion list keeps the URL field's natural on-screen width
    // so cells render full-width; the wrapper's `masksToBounds`
    // clips the portion that extends past the visible panel slice.
    // The leading shift goes negative when the field is left-clipped
    // (`fieldOnScreen.minX < visibleLeft`), matching find bar's
    // `cardLeadingConstraint = naturalLeft - clippedLeft`.
    suggestionListWidthConstraint?.constant = fieldOnScreen.width
    suggestionListLeadingConstraint?.constant = fieldOnScreen.minX - visibleLeft

    // Square off whichever side is hidden behind the window edge so
    // the dropdown reads as "continuing past the screen" instead of
    // a balanced rounded rect that happens to sit at the window
    // boundary. AppKit's coordinate system has y increasing upward,
    // so `MaxY` is the top edge and `MinY` is the bottom edge —
    // both share the clipped horizontal side.
    var corners: CACornerMask = [
      .layerMinXMinYCorner, .layerMinXMaxYCorner,
      .layerMaxXMinYCorner, .layerMaxXMaxYCorner,
    ]
    if fieldOnScreen.minX < windowFrame.minX {
      corners.remove(.layerMinXMinYCorner)
      corners.remove(.layerMinXMaxYCorner)
    }
    if fieldOnScreen.maxX > windowFrame.maxX {
      corners.remove(.layerMaxXMinYCorner)
      corners.remove(.layerMaxXMaxYCorner)
    }
    suggestionWrapperView?.layer?.maskedCorners = corners

    let panelFrame = NSRect(
      x: visibleLeft,
      y: fieldOnScreen.minY - listHeight,
      width: visibleWidth,
      height: listHeight
    )
    panel.setFrame(panelFrame, display: true)
    // Defensive: this file never writes panel.alphaValue. A `< 1`
    // value here means an external cause stuck the panel invisible
    // while it kept dispatching keys — see `logPopupAlphaRecovery`
    // for the candidate causes. The `< 1` gate keeps the normal
    // reposition path silent and routes recoveries through the log.
    // The reset itself is idempotent and so cheap on the hot path
    // (scroll, resize, every keystroke) that keeping the check here
    // instead of at a true "show transition" site is worth the
    // extra coverage.
    if panel.alphaValue < 1 {
      logPopupAlphaRecovery(panel: panel, scope: "url-suggest")
      panel.alphaValue = 1
    }
    panel.orderFront(nil)
  }

  /// Detach the suggestion panel and the workspace scroll observer
  /// when the URL bar leaves its window. The parent window retains
  /// its child windows, so without explicit detachment the panel
  /// would survive past the pane's lifetime in the parent's
  /// child-window list. The scroll observer is released for symmetry
  /// — the next `viewDidMoveToWindow` rebinds whichever scrollView
  /// the URL bar then sits under.
  public override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    guard newWindow == nil else { return }
    if let panel = suggestionPanel {
      panel.orderOut(nil)
      panel.parent?.removeChildWindow(panel)
      suggestionPanel = nil
    }
    if let token = scrollObserver {
      NotificationCenter.default.removeObserver(token)
      scrollObserver = nil
    }
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
    // Subscribe to the workspace clipView's bounds change so the
    // suggestion panel re-anchors to the URL field's screen rect as
    // the user scrolls panes horizontally. The panel lives in screen
    // coordinates, so without this it would sit at the field's
    // pre-scroll position until the next debounce typed-in re-runs
    // `positionSuggestionList`.
    if let token = scrollObserver {
      NotificationCenter.default.removeObserver(token)
      scrollObserver = nil
    }
    if let clipView = enclosingScrollView?.contentView {
      clipView.postsBoundsChangedNotifications = true
      scrollObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: clipView,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, !self.suggestionList.isHidden else { return }
          self.positionSuggestionList()
        }
      }
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

  public override func hitTest(_ point: NSPoint) -> NSView? {
    // The URL bar is a floating overlay over the pane's top edge.
    // When it's collapsed (alpha 0) clicks must reach the page
    // beneath instead of being absorbed by an invisible bar — the
    // overlay otherwise turns the pane's first 28pt into a dead
    // strip. Same pattern as `FindBarView.hitTest`.
    guard alphaValue > 0.01 else { return nil }
    return super.hitTest(point)
  }

  public override func mouseDown(with _: NSEvent) {
    // Absorb empty-area clicks instead of forwarding them up the
    // responder chain. The bar overlays a WKWebView / terminal
    // surface; without this override, clicks landing on the URL
    // bar's chrome (between the buttons and the URL field) bubble
    // through to the page beneath and trigger link activations on
    // whatever happens to be under the cursor — back / forward
    // chevrons aren't usable while a page is loaded behind them.
    onClicked?()
  }

  public override func mouseDragged(with _: NSEvent) {}
  public override func mouseUp(with _: NSEvent) {}

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    // The tracking area uses `.inVisibleRect`, so AppKit re-computes
    // the rect against the live bounds on every event — there is
    // nothing to recreate when the view resizes. Re-adding the area
    // on every layout pass would also re-synthesise `mouseEntered`
    // / `mouseExited` if the cursor happened to be inside the
    // bounds, which fights with the host's hover scheduler. Install
    // the area lazily and leave it in place.
    if hoverTrackingArea != nil { return }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  public override func mouseEntered(with _: NSEvent) {
    // Tracking areas fire even when the bar is alpha 0; the host
    // doesn't want a hover signal from an invisible overlay.
    guard alphaValue > 0.01 else { return }
    onHoverEnter?()
  }

  public override func mouseExited(with _: NSEvent) {
    guard alphaValue > 0.01 else { return }
    // Child tracking areas (HoverIconButton on the back / forward /
    // reload / fold buttons) fire a spurious parent mouseExited
    // when the cursor crosses into their subrect even though the
    // cursor is still inside the URL bar's outer bounds. Re-probe
    // the cursor position and swallow the exit if we're still
    // within the bar — same nested-tracking-area workaround the
    // sidebar uses.
    if cursorIsStillInsideBounds() { return }
    onHoverExit?()
  }

  /// Re-fire `onHoverEnter` if the cursor is already inside the
  /// bar's bounds. AppKit's tracking area only synthesises
  /// `mouseEntered` on bounds *entry* — when the cursor was
  /// already inside while the bar was invisible (alpha 0) and the
  /// bar then flips to visible, the host gets no signal that the
  /// cursor is on the bar. Same pattern as
  /// `EdgeHoverHitZoneView.syncHoverWithCurrentCursor`.
  ///
  /// No alpha guard here on purpose: the host calls this exactly
  /// when it knows a reveal is happening, and a previous version
  /// that gated on `alphaValue > 0.01` accidentally bailed when the
  /// caller was about to animate alpha from 0 to 1 — the model
  /// alpha hadn't been written yet, so the probe never fired and
  /// the host's hover-out timer (queued by the hit zone exit a few
  /// milliseconds earlier) ran to completion and collapsed the
  /// fresh peek. The `mouseEntered` override below still has its
  /// own alpha guard so AppKit-driven entries on an invisible bar
  /// stay silent.
  func syncHoverWithCurrentCursor() {
    guard let window else { return }
    let mouseInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if bounds.contains(mouseInView) {
      onHoverEnter?()
    }
  }

  // MARK: - Public API

  /// Update the displayed URL text.
  public func setDisplayURL(_ urlString: String) {
    writeURLFieldText(urlString)
    if let url = URL(string: urlString),
      let host = url.host(percentEncoded: false), !host.isEmpty
    {
      currentHost = host
    } else {
      currentHost = nil
    }
  }

  /// Enable/disable back and forward buttons.
  public func setNavigationEnabled(back: Bool, forward: Bool) {
    backButton.isEnabled = back
    forwardButton.isEnabled = forward
  }

  /// Enable/disable the reload button. Kept separate from
  /// `setNavigationEnabled(back:forward:)` because availability and
  /// loading state are orthogonal axes — the focused pane may have
  /// nothing to reload (terminal pane, blank surface) even while
  /// `isReloadLoading` stays false.
  public func setReloadEnabled(_ enabled: Bool) {
    reloadButton.isEnabled = enabled
  }

  /// Swap the reload button between its idle (reload) and loading
  /// (stop) presentations. While `loading` is true the icon flips to
  /// `xmark`, the tooltip reads `Stop`, and click routes through
  /// `onStop`; on false it reverts to the reload glyph and
  /// `onReload`. Matches the affordance every mainstream browser
  /// exposes in place of a dedicated stop shortcut.
  public func setReloadButtonLoading(_ loading: Bool) {
    let symbol = loading ? "xmark" : "arrow.clockwise"
    let fallback = loading ? "\u{2715}" : "\u{21BB}"
    let accessibility = loading ? "Stop" : "Reload"
    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
      .withSymbolConfiguration(Self.iconConfig)
    {
      reloadButton.image = image
      reloadButton.imagePosition = .imageOnly
      reloadButton.title = ""
    } else {
      reloadButton.image = nil
      reloadButton.title = fallback
    }
    reloadButton.toolTip = accessibility
    isReloadLoading = loading
  }

  /// Focus the URL field and select all text for quick editing.
  ///
  /// `selectText(nil)` is the final say on selection here: callers
  /// that pre-fill the field via `setDisplayURL` (e.g. `focusURLBar`)
  /// rely on this to override whatever caret position
  /// `writeURLFieldText` parked. Anyone changing the post-focus
  /// selection should walk that prefill chain too.
  public func focusURLField() {
    urlField.refusesFirstResponder = false
    window?.makeFirstResponder(urlField)
    urlField.selectText(nil)
    urlField.refusesFirstResponder = true
  }

  /// Reflect the focused pane's mute / playback state in the speaker
  /// affordance. The button is hidden when the pane has nothing to
  /// say about audio (no active media, or muted on a page that
  /// isn't actually playing anything) so quiet pages don't
  /// accumulate UI noise. Visible when audio is actually emitting
  /// or when the pane is muted but a media element is still active
  /// — that second branch keeps the unmute affordance reachable
  /// after the user mutes an audible pane. When visible:
  ///   - `isMuted` shows `speaker.slash.fill` (struck-through), tip
  ///     "Unmute pane".
  ///   - playing & not muted shows `speaker.wave.2.fill`, tip
  ///     "Mute pane".
  /// Toggles the URL field's leading anchor between reload / mute so
  /// the field reclaims the slot when the speaker disappears.
  public func setMuteState(isMuted: Bool, isPlayingAudio: Bool, hasActiveMedia: Bool) {
    let visible = isPlayingAudio || (isMuted && hasActiveMedia)
    muteButton.isHidden = !visible
    if visible {
      urlFieldLeadingToReload?.isActive = false
      urlFieldLeadingToMute?.isActive = true
    } else {
      urlFieldLeadingToMute?.isActive = false
      urlFieldLeadingToReload?.isActive = true
    }
    let symbol = isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    let accessibility = isMuted ? "Unmute pane" : "Mute pane"
    if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
      .withSymbolConfiguration(Self.iconConfig)
    {
      muteButton.image = image
      muteButton.imagePosition = .imageOnly
      muteButton.title = ""
    } else {
      muteButton.image = nil
      muteButton.title = isMuted ? "\u{1F507}" : "\u{1F50A}"
    }
    muteButton.toolTip = accessibility
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
      extensionsTrailingToZoom?.isActive = false
      extensionsTrailingToFold?.isActive = true
    } else {
      extensionsTrailingToFold?.isActive = false
      extensionsTrailingToZoom?.isActive = true
      zoomPercentLabel.stringValue = "\(Int(round(zoom * 100)))%"
    }
  }

  // MARK: - Suggestions

  private func acceptSuggestion(_ suggestion: Suggestion) {
    writeURLFieldText(suggestion.url)
    dismissSuggestions()
    if let paneID = suggestion.openPaneID {
      onSwitchToPane?(paneID)
    } else {
      onNavigate?(suggestion.url)
    }
  }

  /// Public entry point used by the host (`PaneContainerViewController`)
  /// to close the dropdown synchronously before a workspace slide
  /// animation starts. Without it the focus-loss path
  /// (`controlTextDidEndEditing`'s deferred dismiss) only fires after
  /// `setFocus` has moved first responder, which lands several frames
  /// past the slide's start and leaves the dropdown stranded over the
  /// outgoing workspace for the duration of the animation. Mirrors
  /// `closeFindBar` in the workspace-switch path.
  public func dismissSuggestionDropdown() {
    dismissSuggestions()
  }

  /// Hide the suggestion dropdown AND cancel any debounce timer that
  /// hasn't fired yet. Without the timer cancel, a fast
  /// type→Enter sequence dismisses the list before the debounce
  /// fires, then the deferred `update(items:)` un-hides the
  /// dropdown over the page that navigation has already loaded.
  /// All call sites that intend "the dropdown should stay closed"
  /// must go through here rather than `suggestionList.dismiss()`
  /// directly.
  private func dismissSuggestions() {
    searchDebounceTimer?.invalidate()
    searchDebounceTimer = nil
    suggestionList.dismiss()
    suggestionPanel?.orderOut(nil)
  }

  /// Push `text` into the URL field while keeping the cell value and
  /// the field editor in sync. Writing only `urlField.stringValue`
  /// updates the cell but leaves the shared field editor's glyph
  /// store and selection untouched, so the next time the editor is
  /// re-attached (e.g. the user hits ⌘L again after a navigation)
  /// the stale glyphs paint on top of the fresh cell text and the
  /// caret reads as position 0. Routing through `currentEditor()`
  /// when one exists keeps both stores aligned.
  ///
  /// The end-of-text caret this parks is the safe default for
  /// callers writing into an actively edited field (the user keeps
  /// typing where the new text ends). Focus-shortcut paths that
  /// pre-fill and then call `focusURLField` get their final
  /// selection from `selectText(nil)` instead, matching mainstream
  /// browsers' "select all on ⌘L" behaviour.
  private func writeURLFieldText(_ text: String) {
    if let editor = urlField.currentEditor() {
      editor.string = text
      editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    } else {
      urlField.stringValue = text
    }
  }

  /// Project a `Suggestion` into the presentation-only model consumed by
  /// `SuggestionListView`. The primary line uses `displayTitle` (which
  /// already prefixes bookmarks with `★`); the URL becomes the secondary
  /// line. No accessory is set for URL-bar suggestions — that slot is
  /// reserved for the command-palette action keyboard shortcuts. The
  /// leading image is the host's cached favicon when available, or a
  /// generic `globe` SF Symbol as a placeholder while the fetch warms.
  /// `query` drives substring highlighting so the user sees which
  /// part of the title / URL the matcher anchored on.
  @MainActor
  private static func cellModel(
    from suggestion: Suggestion, query: String
  ) -> SuggestionCellModel {
    let displayTitle = suggestion.displayTitle
    var primaryHighlights: [NSRange] = []
    var secondaryHighlights: [NSRange] = []
    if !query.isEmpty,
      let match = URLMatcher.match(
        query: query,
        title: suggestion.title,
        url: suggestion.url
      )
    {
      // `displayTitle` carries a `★ ` (2-character) prefix only on
      // bookmark rows; everything else renders the title verbatim.
      // Computing the offset from the rendered prefix policy keeps
      // the highlight aligned without depending on the matcher's
      // haystack length, which would mis-align if the matcher ever
      // produced a non-empty title-range against an empty title.
      let prefixOffset = suggestion.isBookmark ? 2 : 0
      let shifted = match.titleRanges.map { range in
        (range.lowerBound + prefixOffset)..<(range.upperBound + prefixOffset)
      }
      primaryHighlights = nsRanges(from: shifted, in: displayTitle)
      secondaryHighlights = nsRanges(from: match.urlRanges, in: suggestion.url)
    }
    // Suggestions whose URL is already open elsewhere render with a
    // trailing "Switch to Pane" hint so the user knows Enter (or a
    // click) lifts the existing pane into focus rather than queueing
    // a fresh navigation.
    let accessory: String? = suggestion.openPaneID != nil ? "Switch to Pane" : nil
    return SuggestionCellModel(
      primary: displayTitle,
      secondary: suggestion.url,
      accessory: accessory,
      leadingImage: faviconImage(for: suggestion.url),
      primaryHighlights: primaryHighlights,
      secondaryHighlights: secondaryHighlights
    )
  }

  /// Resolve the host from `urlString` and return the matching favicon
  /// from the shared cache. Falls back to a `globe` SF Symbol when the
  /// host is missing, untracked, or the cache hasn't resolved it yet —
  /// the same placeholder the sidebar worklane uses, so cold rows in
  /// both surfaces look consistent. Search-engine rows get a dedicated
  /// magnifying-glass icon so the row reads as an action rather than
  /// a navigation to the search engine's homepage.
  @MainActor
  private static func faviconImage(for urlString: String) -> NSImage? {
    if PaneAddress.isSearchQuery(urlString: urlString) {
      return NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
    }
    if let url = URL(string: urlString),
      let host = url.host(percentEncoded: false),
      !host.isEmpty,
      let image = FaviconCache.shared.image(for: host)
    {
      return image
    }
    return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
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
    if isReloadLoading {
      onStop?()
    } else {
      onReload?()
    }
  }

  @objc private func muteAction() {
    onClicked?()
    onMuteToggle?()
  }

  @objc private func muteSiteAction(_ sender: NSMenuItem) {
    guard let host = sender.representedObject as? String else { return }
    onClicked?()
    onMuteSiteToggle?(host)
  }

  // MARK: - NSMenuDelegate (speaker right-click)

  /// Rebuild the speaker's right-click menu against the current
  /// host so the label flips between "Mute this Site" and "Unmute
  /// this Site" as the persistent state changes. The current host
  /// is captured per call so the menu reflects whatever URL the
  /// host last passed through `setDisplayURL`; a host-less bar
  /// (terminal / finder pane, or a non-URL display) yields an
  /// empty menu so the right-click reads as a no-op rather than
  /// dispatching against the wrong site.
  public func menuNeedsUpdate(_ menu: NSMenu) {
    guard menu === muteButton.menu else { return }
    menu.removeAllItems()
    guard let host = currentHost else { return }
    let isSiteMuted = MutedSitesStore.shared.isMuted(host: host)
    let title = isSiteMuted ? "Unmute this Site" : "Mute this Site"
    let item = NSMenuItem(
      title: title, action: #selector(muteSiteAction(_:)), keyEquivalent: "")
    item.target = self
    item.representedObject = host
    menu.addItem(item)
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
      dismissSuggestions()
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
        self.suggestionList.update(
          items: suggestions.map { Self.cellModel(from: $0, query: text) }
        )
        self.positionSuggestionList()
      }
    }
  }

  public func control(_ control: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(insertNewline(_:)) {
      if !suggestionList.isHidden,
        let index = suggestionList.selectedIndex,
        currentSuggestions.indices.contains(index)
      {
        acceptSuggestion(currentSuggestions[index])
      } else {
        onNavigate?(urlField.stringValue)
      }
      dismissSuggestions()
      return true
    }
    if selector == #selector(cancelOperation(_:)) {
      dismissSuggestions()
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
      // `focusURLField` calls `selectText(nil)` right after
      // `makeFirstResponder`, which internally tears down and rebuilds
      // the shared field editor — that round-trip fires a transient
      // didEnd → didBegin pair while the user is still mid-focus. By
      // the time this async lands, the field editor has reattached and
      // `currentEditor()` is non-nil again. Bailing here keeps a real
      // blur from being indistinguishable from this re-attach blip,
      // which would otherwise let `onEditingEndedOutsideBar` fire and
      // collapse the peek the moment ⌘L opened it.
      if self.urlField.currentEditor() != nil { return }
      // If the new first responder is inside the suggestion list,
      // the user clicked a row — don't dismiss yet; handleClick
      // will dismiss after accepting the selection.
      if let responder = self.window?.firstResponder as? NSView,
        responder.isDescendant(of: self.suggestionList)
      {
        return
      }
      self.dismissSuggestions()
      // Tell the host editing has ended with the cursor outside the
      // bar so the peek can collapse right away. While the field
      // editor was attached, hover-out fires were suppressed
      // (`isEditing` guard in `scheduleURLBarHoverOut`) to keep the
      // bar anchored under the user's typing — we own the close
      // here. Routing through the regular hover scheduler would
      // queue another 300ms wait that the user can't see any
      // benefit from once they've already given up first responder.
      if !self.cursorIsStillInsideBounds() {
        self.onEditingEndedOutsideBar?()
      }
    }
  }
}
