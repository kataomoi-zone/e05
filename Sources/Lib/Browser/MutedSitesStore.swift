import Foundation

/// Per-host site mute preferences, mirrored to
/// `~/Library/Application Support/<bundle-id>/muted-sites.json`. A thin
/// domain-named wrapper over ``HostSetStore``, which owns the shared
/// versioned-wrapper / lowercase / quarantine / rollback machinery.
/// The set holds fully-qualified hosts (`mail.google.com` is distinct
/// from `docs.google.com`) so each subdomain decides its own noise
/// budget.
@MainActor
public final class MutedSitesStore {
  /// Process-wide store. Browser panes share this instance so a "Mute
  /// this Site" toggle in one tab is observed by every other tab on the
  /// same host without each pane keeping its own copy.
  public static let shared = MutedSitesStore()

  private let store: HostSetStore

  /// Production initialiser reads
  /// `~/Library/Application Support/<bundle-id>/muted-sites.json`. Pass
  /// `inMemory: true` from tests to keep the set ephemeral and avoid
  /// touching the user's real data directory.
  public convenience init(inMemory: Bool = false) {
    self.init(storeURL: inMemory ? nil : E05Paths.default.dataFile(E05Filenames.mutedSites))
  }

  /// Internal initialiser that drives the on-disk format against an
  /// arbitrary file URL. Tests use this to exercise `save` / `load`
  /// end-to-end against a temp file; `nil` keeps the set ephemeral.
  init(storeURL: URL?) {
    store = HostSetStore(storeURL: storeURL, label: E05Filenames.mutedSites)
  }

  /// Whether `host` is on the always-mute list (case-insensitive).
  public func isMuted(host: String) -> Bool {
    store.contains(host)
  }

  /// Every host on the always-mute list, sorted.
  public var allHosts: [String] {
    store.allHosts
  }

  /// Add or remove `host` from the always-mute list and persist. The
  /// caller is responsible for propagating the toggle to live panes
  /// (see `PaneContainerViewController.applyMuteToPanes(matchingHost:muted:)`)
  /// — there's no broadcast notification because the only consumer that
  /// needs to react synchronously is the toggle's own call site.
  public func setMuted(_ muted: Bool, host: String) {
    store.set(muted, host: host)
  }
}
