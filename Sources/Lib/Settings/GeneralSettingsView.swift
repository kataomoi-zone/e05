import AppKit
import SwiftUI

/// "General" tab content. Four sections cover the cross-app hardcodes
/// that the preferences store replaces: the home URL fed to a fresh
/// browser pane, the pane kind a new workspace seeds, the search
/// engine template the URL bar uses when the input does not parse as a
/// URL, and the download destination policy (always-prompt vs.
/// silent-save-to-folder).
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
  /// Store-listener handle. Held in state so `.onDisappear` can
  /// unsubscribe, preventing the listener from outliving the view
  /// when the tab is swapped out.
  @State private var listenerToken: UUID?

  init() {
    let current = PreferencesStore.shared.preferences
    _preferences = State(initialValue: current)
    _homeURLInput = State(initialValue: current.homeURL ?? "")
    _homeOption = State(initialValue: current.homeURL == nil ? .blank : .custom)
    _selectedSearchPreset = State(
      initialValue: SearchEnginePreset.matching(template: current.searchTemplate))
    _initialPaneKind = State(
      initialValue: InitialPaneKindPreset.resolve(current.initialPaneKind))
  }

  var body: some View {
    Form {
      Section("Homepage") {
        Picker("New panes open", selection: $homeOption) {
          Text("Blank page").tag(HomeOption.blank)
          Text("Specific URL").tag(HomeOption.custom)
        }
        .pickerStyle(.radioGroup)
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
            .onSubmit { writeHomeURL() }
            .onChange(of: homeURLInput) { _, _ in writeHomeURL() }
        }
      }

      Section("New Workspace") {
        Picker("Initial pane", selection: $initialPaneKind) {
          ForEach(InitialPaneKindPreset.allCases) { kind in
            Label(kind.displayName, systemImage: kind.symbol).tag(kind)
          }
        }
        .onChange(of: initialPaneKind) { _, kind in
          preferences.initialPaneKind = kind.rawValue
          persist()
        }
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
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { subscribeToStore() }
    .onDisappear { unsubscribeFromStore() }
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

  /// Render the configured / fallback download directory with the
  /// user's home replaced by `~`. `homeDirectoryForCurrentUser` may
  /// hand back a path with a trailing slash on some macOS versions,
  /// so strip it before the prefix check or the leading `/` of the
  /// child path gets eaten and the result reads as `~Downloads`.
  private var displayedDownloadDir: String {
    let raw =
      preferences.defaultDownloadDir
      ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
      .first?.path(percentEncoded: false)
      ?? "~/Downloads"
    var home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    while home.hasSuffix("/") { home.removeLast() }
    if raw == home { return "~" }
    if raw.hasPrefix(home + "/") {
      return "~" + raw.dropFirst(home.count)
    }
    return raw
  }

  private func writeHomeURL() {
    let trimmed = homeURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
    preferences.homeURL = trimmed.isEmpty ? nil : trimmed
    persist()
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
