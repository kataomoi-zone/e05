import Foundation

/// One pane of the Settings window. `allCases` order drives the
/// sidebar row order: About sits at the bottom by convention so the
/// most-edited tabs (General first, then Appearance, then Terminal /
/// Sites / Shortcuts / Content Blocker) stay near the top. Appearance
/// sits right after General because its theme and pane-width presets
/// are the settings most often reached for after the General defaults.
///
/// Lives in its own file rather than nested in ``SettingsRootView``
/// because the cross-tab search index (``SettingsSearchIndex``) keys
/// every searchable setting back to the tab that owns it.
enum SettingsTab: CaseIterable, Hashable, Identifiable, Sendable {
  case general
  case appearance
  case terminal
  case sites
  case shortcuts
  case contentBlocker
  case about

  var id: Self { self }

  var title: String {
    switch self {
    case .general: "General"
    case .terminal: "Terminal"
    case .sites: "Sites"
    case .appearance: "Appearance"
    case .shortcuts: "Shortcuts"
    case .contentBlocker: "Content Blocker"
    case .about: "About"
    }
  }

  /// SF Symbol for the sidebar row. Picked from system symbols so a
  /// theme switch picks up the appearance automatically.
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .terminal: "terminal"
    case .sites: "globe"
    case .appearance: "paintbrush.fill"
    case .shortcuts: "keyboard"
    case .contentBlocker: "shield.lefthalf.filled"
    case .about: "info.circle"
    }
  }
}
