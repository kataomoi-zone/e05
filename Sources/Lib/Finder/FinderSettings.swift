import Foundation

/// Global, UserDefaults-backed settings for all finder panes.
///
/// The visibility state is intentionally process-global: Finder on
/// macOS treats "show hidden files" as a single application-wide
/// toggle, so a single setting flipping every open finder pane at
/// once matches the behaviour users already know. Per-pane overrides
/// would also need a place to live in `session.json`; a single
/// `UserDefaults` key sidesteps schema churn entirely.
///
/// Observers (today: `FinderPaneView`) subscribe to
/// ``didChangeNotification`` and reload their directory listings on
/// post, so the flip is visible immediately across every pane.
@MainActor
public enum FinderSettings {
  /// Posted on the main actor after any setting flips. `object` is
  /// left nil — a coarse "something changed" signal is enough because
  /// there's only one setting today and the receiver's reload is
  /// cheap (one directory enumerate per open finder pane).
  public static let didChangeNotification = Notification.Name("FinderSettingsDidChange")

  private static let hiddenFilesKey = "finder.showHiddenFiles"

  /// Whether hidden files (dotfiles, `~/Library`, etc.) appear in
  /// finder pane listings. `false` by default, matching Finder's
  /// out-of-the-box state. `UserDefaults.standard.bool(forKey:)`
  /// returns `false` for unset keys, so no `register(defaults:)`
  /// call is needed to pin that default.
  public static var showHiddenFiles: Bool {
    UserDefaults.standard.bool(forKey: hiddenFilesKey)
  }

  /// Flip the hidden-files setting and broadcast the change so every
  /// open finder pane can re-read its directory with the new filter.
  public static func toggleShowHiddenFiles() {
    UserDefaults.standard.set(!showHiddenFiles, forKey: hiddenFilesKey)
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}
