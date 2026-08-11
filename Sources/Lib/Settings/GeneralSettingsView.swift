import AppKit
import SwiftUI

/// "General" tab content. Sections cover the cross-app hardcodes that
/// the preferences store replaces: the blank / home URL fed to a fresh
/// browser pane, the cwd / root folder a new terminal / finder pane
/// opens in, the pane kind `Split Vertical` and a new workspace seed,
/// the search engine template the URL bar uses when the input does not
/// parse as a URL, and the download destination policy (always-prompt
/// vs. silent-save-to-folder).
///
/// State binds to a local copy of the preferences. The shared store
/// is the single source of truth; the view writes back through
/// ``PreferencesStore.update(_:)`` on every change so each tweak
/// hits disk before the user moves to the next field.
@MainActor
struct GeneralSettingsView: View {
  @State private var preferences: E05Preferences
  @State private var homeURLInput: String
  /// View-local home option so picking `.custom` with an empty input
  /// stays sticky. Deriving the option from `preferences.homeURL ==
  /// nil` would flip the picker back to `.blank` immediately because
  /// an empty trimmed input persists as `nil`, leaving no way to
  /// type the URL after selecting Specific URL.
  @State private var homeOption: HomeOption
  /// View-local selection so picking ``SearchEnginePreset/custom``
  /// stays sticky. ``SearchEnginePreset/matching(template:)`` cannot
  /// recover `.custom` from a stored template that happens to equal
  /// a built-in preset, so the choice has to live in view state
  /// rather than be re-derived from preferences on every render.
  @State private var selectedSearchPreset: SearchEnginePreset
  /// Pane kind seeded into a freshly created workspace. Maps 1:1 to
  /// the stored identifier, so it can be re-derived from preferences
  /// on every external mutation (no sticky `.custom` case to preserve
  /// the way the home / search pickers need).
  @State private var initialPaneKind: InitialPaneKindPreset
  /// Pane kind opened by `Split Vertical`. 1:1 with the stored
  /// identifier, like ``initialPaneKind``.
  @State private var splitPaneKind: SplitPaneKindPreset
  /// View-local terminal-cwd option so picking `.custom` without yet
  /// choosing a folder stays sticky (an empty custom path persists as
  /// `nil`, which would otherwise snap the picker back to `.inherit`).
  @State private var terminalDirOption: DirOption
  /// View-local finder-root option, sticky for the same reason as
  /// ``terminalDirOption``.
  @State private var finderDirOption: DirOption
  /// Store-listener handle. Held in state so `.onDisappear` can
  /// unsubscribe, preventing the listener from outliving the view
  /// when the tab is swapped out.
  @State private var listenerToken: UUID?
  /// Tracks focus on the Specific-URL field so the scheme is supplied
  /// the moment it loses focus (clicking another control, tabbing, or
  /// switching settings tabs), not only on Enter.
  @FocusState private var urlFieldFocused: Bool
  /// Sparkle's own settings, mirrored here for binding. Seeded in
  /// `.onAppear` rather than `init` because the permission prompt or a
  /// menu-driven check can change them behind this view's back.
  @State private var autoCheckUpdates = false
  @State private var autoInstallUpdates = false
  @State private var lastUpdateCheck: Date?

  init() {
    let current = PreferencesStore.shared.preferences
    _preferences = State(initialValue: current)
    _homeURLInput = State(initialValue: current.homeURL ?? "")
    _homeOption = State(initialValue: current.homeURL == nil ? .blank : .custom)
    _selectedSearchPreset = State(
      initialValue: SearchEnginePreset.matching(template: current.searchTemplate))
    _initialPaneKind = State(
      initialValue: InitialPaneKindPreset.resolve(current.initialPaneKind))
    _splitPaneKind = State(
      initialValue: SplitPaneKindPreset.resolve(current.splitPaneKind))
    _terminalDirOption = State(
      initialValue: current.newTerminalDirectory?.isEmpty == false ? .custom : .inherit)
    _finderDirOption = State(
      initialValue: current.newFinderDirectory?.isEmpty == false ? .custom : .inherit)
  }

  var body: some View {
    Form {
      // One section for every "what does a freshly opened pane start
      // with" default, so the related settings don't sprawl across a
      // section apiece.
      Section("New Panes") {
        Picker("Browser pane", selection: $homeOption) {
          Text("Blank page").tag(HomeOption.blank)
          Text("Specific URL").tag(HomeOption.custom)
        }
        .onChange(of: homeOption) { _, option in
          switch option {
          case .blank:
            // Keep `homeURLInput` so re-selecting Specific URL
            // restores what the user typed before — only the
            // persisted value drops to nil.
            preferences.homeURL = nil
            persist()
          case .custom:
            writeHomeURL()
          }
        }

        if homeOption == .custom {
          // `labelsHidden` keeps the field flush-left of the form
          // column. Without it, the first argument string becomes a
          // form label rendered on the left side, which looks like
          // a clickable link adjacent to the input.
          TextField("URL", text: $homeURLInput, prompt: Text("https://example.com"))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .focused($urlFieldFocused)
            .onSubmit { commitHomeURL() }
            .onChange(of: homeURLInput) { _, _ in writeHomeURL() }
            .onChange(of: urlFieldFocused) { _, focused in
              if !focused { commitHomeURL() }
            }
        }

        Picker("Terminal pane", selection: $terminalDirOption) {
          // "Latest", not "focused": the focused pane may be a browser
          // / finder, so libghostty seeds the cwd from the most recent
          // terminal surface.
          Text("Inherit from latest terminal").tag(DirOption.inherit)
          Text("Specific folder").tag(DirOption.custom)
        }
        .onChange(of: terminalDirOption) { _, option in
          // `.inherit` clears the stored path; `.custom` seeds the home
          // directory (rather than an empty "not set") so the row below
          // is immediately meaningful.
          preferences.newTerminalDirectory = dirOptionValue(
            option, current: preferences.newTerminalDirectory)
          persist()
        }

        if terminalDirOption == .custom {
          folderRow(path: preferences.newTerminalDirectory, choose: pickTerminalDir)
        }

        Picker("Finder pane", selection: $finderDirOption) {
          Text("Inherit from latest finder").tag(DirOption.inherit)
          Text("Specific folder").tag(DirOption.custom)
        }
        .onChange(of: finderDirOption) { _, option in
          preferences.newFinderDirectory = dirOptionValue(
            option, current: preferences.newFinderDirectory)
          persist()
        }

        if finderDirOption == .custom {
          folderRow(path: preferences.newFinderDirectory, choose: pickFinderDir)
        }

        Picker("Split Vertical", selection: $splitPaneKind) {
          ForEach(SplitPaneKindPreset.allCases) { kind in
            Label(kind.displayName, systemImage: kind.symbol).tag(kind)
          }
        }
        .onChange(of: splitPaneKind) { _, kind in
          preferences.splitPaneKind = kind.rawValue
          persist()
        }

        Picker("New workspace", selection: $initialPaneKind) {
          ForEach(InitialPaneKindPreset.allCases) { kind in
            Label(kind.displayName, systemImage: kind.symbol).tag(kind)
          }
        }
        .onChange(of: initialPaneKind) { _, kind in
          preferences.initialPaneKind = kind.rawValue
          persist()
        }
      }

      Section("Navigation") {
        // Bool? fields: nil means "keep the historical default", so the
        // toggles read through a `?? default` and write the explicit
        // value. Wrapping is the default for focus moves; the palette's
        // cross-workspace listing is the default for Focus search.
        Toggle(
          "Wrap around at the first and last pane",
          isOn: Binding(
            get: { preferences.wrapPaneFocus ?? true },
            set: {
              preferences.wrapPaneFocus = $0
              persist()
            }))
        Toggle(
          "Wrap around at the first and last workspace",
          isOn: Binding(
            get: { preferences.wrapWorkspaceSwitch ?? true },
            set: {
              preferences.wrapWorkspaceSwitch = $0
              persist()
            }))
        Toggle(
          "Limit palette Focus search to the current workspace",
          isOn: Binding(
            get: { preferences.paletteFocusCurrentWorkspaceOnly ?? false },
            set: {
              preferences.paletteFocusCurrentWorkspaceOnly = $0
              persist()
            }))
      }

      Section("Search Engine") {
        Picker("Engine", selection: $selectedSearchPreset) {
          ForEach(SearchEnginePreset.allCases) { preset in
            Text(preset.displayName).tag(preset)
          }
        }
        .onChange(of: selectedSearchPreset) { _, preset in
          // Built-in presets overwrite the template so the URL bar
          // immediately switches engines. `.custom` leaves the
          // template alone — the TextField below is the next edit
          // surface — so a user moving Built-in → Custom keeps
          // whatever template they had.
          if let template = preset.template {
            preferences.searchTemplate = template
            persist()
          }
        }

        if selectedSearchPreset == .custom {
          TextField(
            "Template",
            text: $preferences.searchTemplate,
            prompt: Text("https://example.com/?q={query}")
          )
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
          .onChange(of: preferences.searchTemplate) { _, _ in persist() }
        }
      }

      Section("Downloads") {
        Toggle("Ask where to save each file", isOn: $preferences.alwaysPromptDownload)
          .onChange(of: preferences.alwaysPromptDownload) { _, _ in persist() }

        // Always visible so the "save here, but still ask" and
        // "save somewhere else, no prompt" combinations both stay
        // configurable from one screen.
        HStack(alignment: .firstTextBaseline) {
          Text("Save to")
          Spacer()
          Text(displayedDownloadDir)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Button("Choose…") { pickDownloadDir() }
        }
      }

      Section {
        Toggle(
          "Restore terminal scrollback after a restart",
          isOn: Binding(
            get: { preferences.restoresTerminalScrollback },
            set: {
              preferences.restoreTerminalScrollback = $0
              persist()
            }))
        // Facts the user needs to decide, and nothing else: what lands
        // in the file, how to get rid of it, and which shells replay it.
        // How much the shells are exercised belongs in the README, not
        // in the app.
        Text(
          """
          Each terminal pane's screen is written to a file at quit and printed back by the \
          shell on the next launch. The file holds whatever was on screen, which can include \
          a token you echoed or the output of `env`. Turning this off stops new ones being \
          written and deletes the ones already saved at the next quit; Settings → About → \
          Reset deletes them now.

          Replaying needs zsh, bash or fish. A pane running another shell opens without its \
          history.
          """
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } header: {
        Text("Terminal")
      }

      // Sparkle owns these settings in its own defaults, so they are
      // read from and written to the updater rather than through
      // PreferencesStore like everything else on this screen. Without
      // this section the only chance to set them is the permission
      // prompt on first launch.
      Section("Updates") {
        Toggle("Check for updates automatically", isOn: $autoCheckUpdates)
          .onChange(of: autoCheckUpdates) { _, value in
            UpdateController.shared.automaticallyChecksForUpdates = value
          }

        Toggle("Download and install automatically", isOn: $autoInstallUpdates)
          .onChange(of: autoInstallUpdates) { _, value in
            UpdateController.shared.automaticallyDownloadsUpdates = value
          }
          // Meaningless on its own — Sparkle has to find an update
          // before it can install one.
          .disabled(!autoCheckUpdates)

        HStack(alignment: .firstTextBaseline) {
          Text("Last checked")
          Spacer()
          Text(lastUpdateCheckLabel)
            .foregroundStyle(.secondary)
          Button("Check Now") {
            UpdateController.shared.checkForUpdates()
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      subscribeToStore()
      // Re-read on every appearance: the permission prompt, a manual
      // check, or the menu entry can all have moved these since the
      // view was constructed.
      autoCheckUpdates = UpdateController.shared.automaticallyChecksForUpdates
      autoInstallUpdates = UpdateController.shared.automaticallyDownloadsUpdates
      lastUpdateCheck = UpdateController.shared.lastUpdateCheckDate
    }
    .onDisappear { unsubscribeFromStore() }
  }

  /// Absolute rather than relative ("2 hours ago"): the value only
  /// refreshes when the view appears, so a relative string would drift
  /// into being wrong while the window sits open.
  private var lastUpdateCheckLabel: String {
    guard let date = lastUpdateCheck else { return "Never" }
    return date.formatted(date: .abbreviated, time: .shortened)
  }

  // MARK: - Store subscription

  /// Pull external mutations (Import / Reset / future tabs) into the
  /// view-local copy. Without this, the view shows the stale
  /// snapshot captured at `init` until the user re-opens Settings.
  private func subscribeToStore() {
    if listenerToken != nil { return }
    listenerToken = PreferencesStore.shared.addListener { new in
      preferences = new
      homeURLInput = new.homeURL ?? ""
      homeOption = new.homeURL == nil ? .blank : .custom
      selectedSearchPreset = SearchEnginePreset.matching(template: new.searchTemplate)
      initialPaneKind = InitialPaneKindPreset.resolve(new.initialPaneKind)
      splitPaneKind = SplitPaneKindPreset.resolve(new.splitPaneKind)
      terminalDirOption = new.newTerminalDirectory?.isEmpty == false ? .custom : .inherit
      finderDirOption = new.newFinderDirectory?.isEmpty == false ? .custom : .inherit
    }
  }

  private func unsubscribeFromStore() {
    if let token = listenerToken {
      PreferencesStore.shared.removeListener(token)
      listenerToken = nil
    }
  }

  // MARK: - Helpers

  private enum HomeOption { case blank, custom }
  /// Shared by the terminal-cwd and finder-root rows: inherit the
  /// latest pane of that kind, or pin a specific folder.
  private enum DirOption { case inherit, custom }

  /// Render the configured / fallback download directory with the
  /// user's home replaced by `~`.
  private var displayedDownloadDir: String {
    let raw =
      preferences.defaultDownloadDir
      ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
      .first?.path(percentEncoded: false)
      ?? "~/Downloads"
    return abbreviatingHome(raw)
  }

  /// Replace the user's home prefix with `~`. Both `raw` and
  /// `homeDirectoryForCurrentUser` may carry a trailing slash (the
  /// open panel and some macOS versions add one), so strip both before
  /// comparing — otherwise the home directory itself renders as `~/`
  /// and a child path's leading `/` gets eaten into `~Downloads`.
  private func abbreviatingHome(_ raw: String) -> String {
    var home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    while home.hasSuffix("/") { home.removeLast() }
    var path = raw
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    if path == home { return "~" }
    if path.hasPrefix(home + "/") {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }

  /// New value for a directory preference when its inherit / custom
  /// radio flips: `.inherit` clears it, `.custom` seeds the home
  /// directory (`~`) so the folder row starts at a real default rather
  /// than an empty "not set".
  private func dirOptionValue(_ option: DirOption, current: String?) -> String? {
    switch option {
    case .inherit: return nil
    case .custom: return current?.isEmpty == false ? current : "~"
    }
  }

  /// Indented folder display + "Choose…" row shared by the terminal /
  /// finder pickers. The leading inset reads the row as a child of the
  /// picker above it. Falls back to `~` (home), which is also the value
  /// `.custom` seeds, so the row never shows an empty path.
  @ViewBuilder
  private func folderRow(path: String?, choose: @escaping () -> Void) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Folder")
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
      Spacer()
      Text(path.flatMap { $0.isEmpty ? nil : abbreviatingHome($0) } ?? "~")
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Button("Choose…", action: choose)
    }
  }

  private func writeHomeURL() {
    let trimmed = homeURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
    preferences.homeURL = trimmed.isEmpty ? nil : trimmed
    persist()
  }

  /// Normalize the home URL field on commit (Enter): supply `https://`
  /// for a bare host so the field shows the same URL that will load,
  /// matching Brave. Live edits keep storing the raw text (`writeHomeURL`
  /// on change) so the scheme isn't prepended mid-typing; `newPaneHome`
  /// applies the same normalization at use, covering uncommitted values.
  private func commitHomeURL() {
    let trimmed = homeURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
    if let normalized = PaneAddress.fromUserInput(trimmed)?.url.absoluteString {
      homeURLInput = normalized
    }
    writeHomeURL()
  }

  private func pickDownloadDir() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = "Choose default download directory"
    panel.prompt = "Choose"
    // Start the picker at whatever the preference currently resolves
    // to (configured dir, or `~/Downloads` fallback) so the user
    // sees the "current value" highlighted instead of NSOpenPanel's
    // last-used directory.
    panel.directoryURL = DownloadsManager.resolveDownloadBaseDir()
    // Sheet-attach to the Settings panel so a Cancel returns focus
    // to Settings itself; `runModal()` is app-modal and parks the
    // key window on whichever NSWindow was active before the panel
    // opened (typically the main e05 window), which makes the user
    // re-click the panel to keep editing.
    guard let parent = SettingsWindowController.shared.window else { return }
    panel.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        guard response == .OK, let url = panel.url else { return }
        preferences.defaultDownloadDir = url.path(percentEncoded: false)
        persist()
      }
    }
  }

  private func pickTerminalDir() {
    pickFolder(
      message: "Choose the default terminal directory", current: preferences.newTerminalDirectory
    ) { path in
      preferences.newTerminalDirectory = path
      persist()
    }
  }

  private func pickFinderDir() {
    pickFolder(
      message: "Choose the default finder directory", current: preferences.newFinderDirectory
    ) { path in
      preferences.newFinderDirectory = path
      persist()
    }
  }

  /// Sheet-attached directory picker shared by the terminal / finder
  /// folder rows. Seeds the panel at the current value (or home) so the
  /// user starts from the configured folder, matching `pickDownloadDir`.
  /// `apply` receives the chosen path with any trailing slash stripped
  /// so the stored value (and its `~` abbreviation) stays canonical —
  /// picking the home folder yields `~`, not `~/`.
  private func pickFolder(message: String, current: String?, apply: @escaping (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = "Choose"
    if let current, !current.isEmpty {
      panel.directoryURL = URL(
        fileURLWithPath: (current as NSString).expandingTildeInPath, isDirectory: true)
    } else {
      panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    }
    guard let parent = SettingsWindowController.shared.window else { return }
    panel.beginSheetModal(for: parent) { response in
      MainActor.assumeIsolated {
        guard response == .OK, let url = panel.url else { return }
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        apply(path)
      }
    }
  }

  private func persist() {
    let snapshot = preferences
    PreferencesStore.shared.update { $0 = snapshot }
  }
}

/// Built-in search engine choices. Keeping `template` next to the
/// preset name means the URL bar's hostname inference (which uses the
/// host of the template to suppress "switch to existing pane" hints
/// on result pages) stays driven by a single table.
private enum SearchEnginePreset: String, CaseIterable, Identifiable {
  case duckduckgo
  case google
  case bing
  case brave
  case custom

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .duckduckgo: "DuckDuckGo"
    case .google: "Google"
    case .bing: "Bing"
    case .brave: "Brave"
    case .custom: "Custom"
    }
  }

  /// `nil` for `.custom` — the user-typed template wins, the preset
  /// just signals "do not overwrite my template".
  var template: String? {
    switch self {
    case .duckduckgo: "https://duckduckgo.com/?q={query}"
    case .google: "https://www.google.com/search?q={query}"
    case .bing: "https://www.bing.com/search?q={query}"
    case .brave: "https://search.brave.com/search?q={query}"
    case .custom: nil
    }
  }

  /// Initial preset for a stored template. Built-in matches win; an
  /// unfamiliar template lands on `.custom` so first-launch with a
  /// hand-edited preferences file does not silently rebrand.
  static func matching(template: String) -> SearchEnginePreset {
    for preset in allCases where preset.template == template {
      return preset
    }
    return .custom
  }
}
