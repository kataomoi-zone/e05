import Foundation

/// User-defined filterlist URL persisted in
/// ``E05Preferences/adblockerCustomSources``. The runtime adapter on
/// ``AdBlocker`` maps each entry to a ``AdBlocker/FilterSource`` with
/// a `"custom-"` id prefix so the id namespace stays disjoint from the
/// shipped catalog.
///
/// `url` and `homepage` stay as ``String`` rather than ``URL`` to
/// keep the JSON shape forgiving — a hand-edited preferences file
/// with a typo still decodes, and the adapter drops entries whose
/// `url` does not parse to a `http`/`https` URL at runtime.
public struct AdblockerCustomSource: Codable, Equatable, Sendable, Identifiable {
  /// Opaque ULID for this entry. The ``AdBlocker/FilterSource.id``
  /// the runtime sees is `"custom-" + id`, which keeps user-edited
  /// `adblockerEnabledSources` entries readable when grepping the
  /// preferences file.
  public let id: String
  public var name: String
  public let url: String
  public var homepage: String?
  public let addedAt: Date

  public init(
    id: String, name: String, url: String, homepage: String? = nil,
    addedAt: Date = Date()
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.homepage = homepage
    self.addedAt = addedAt
  }
}
