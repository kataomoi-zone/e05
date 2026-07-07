import Foundation

/// Per-host "always keep active" preferences, mirrored to
/// `~/Library/Application Support/<bundle-id>/suspend-exempt.json`. A
/// thin domain-named wrapper over ``HostSetStore``, which owns the
/// shared versioned-wrapper / lowercase / quarantine / rollback
/// machinery. The set holds fully-qualified hosts (`mail.google.com` is
/// distinct from `docs.google.com`) so each subdomain decides its own
/// suspend budget.
@MainActor
public final class SuspendHostExemptStore {
  /// Process-wide store. Suspend sweeps and the surface that toggles
  /// individual hosts share this instance so a change in one is observed
  /// by the other without each caller keeping its own copy.
  public static let shared = SuspendHostExemptStore()

  private let store: HostSetStore

  /// Production initialiser reads
  /// `~/Library/Application Support/<bundle-id>/suspend-exempt.json`.
  /// Pass `inMemory: true` from tests to keep the set ephemeral and
  /// avoid touching the user's real data directory.
  public convenience init(inMemory: Bool = false) {
    self.init(storeURL: inMemory ? nil : E05Paths.default.dataFile(E05Filenames.suspendExempt))
  }

  /// Internal initialiser that drives the on-disk format against an
  /// arbitrary file URL. Tests use this to exercise `save` / `load`
  /// end-to-end against a temp file; `nil` keeps the set ephemeral.
  init(storeURL: URL?) {
    store = HostSetStore(storeURL: storeURL, label: E05Filenames.suspendExempt)
  }

  /// Whether `host` is on the always-active list (case-insensitive).
  public func isExempt(host: String) -> Bool {
    store.contains(host)
  }

  /// Every host on the always-active list, sorted.
  public var allHosts: [String] {
    store.allHosts
  }

  /// Add or remove `host` from the always-active list and persist.
  public func setExempt(_ exempt: Bool, host: String) {
    store.set(exempt, host: host)
  }

  /// Drop `host` from the always-active list. Convenience wrapper
  /// matching the `remove(host:)` shape shared across host-keyed stores.
  public func remove(host: String) {
    store.set(false, host: host)
  }
}
