import Foundation

/// Frequency × recency score for a single history URL, used to surface
/// frequently-visited recent pages near the top of URL-bar
/// suggestions. Higher means more likely to be the destination the
/// user wants.
///
/// Models the Chromium/Firefox omnibox idea that *how* a page was
/// reached matters: a page the user typed into the address bar
/// expresses direct intent and counts for far more than an incidental
/// link follow. Visits are weighted by kind, then decayed by how long
/// ago the last visit was. The decay is bucketed (rather than a smooth
/// half-life) so scores stay reproducible without depending on
/// floating-point timing.
public enum Frecency {
  /// Weight per visit kind. The typed:link ratio mirrors Firefox's
  /// `typedVisitBonus` (2000) vs `linkVisitBonus` (100) ≈ 20×, so a
  /// single address-bar navigation outweighs a handful of link
  /// follows to the same page.
  static let typedWeight = 20.0
  static let linkWeight = 1.0

  /// Last-visit recency multiplier, aligned with the
  /// Chromium/Firefox 4 / 14 / 31 / 90 day bucket cutoffs.
  static func recencyFactor(ageSeconds: Double) -> Double {
    switch ageSeconds {
    case ..<345_600: return 1.0  // < 4 days
    case ..<1_209_600: return 0.7  // < 14 days
    case ..<2_678_400: return 0.5  // < 31 days
    case ..<7_776_000: return 0.3  // < 90 days
    default: return 0.1
    }
  }

  /// Score one URL's aggregate. `typedVisits` is clamped to `visits`
  /// so a malformed count can't inflate the score past all-typed.
  public static func score(
    visits: Int, typedVisits: Int, lastVisit: Date, now: Date
  ) -> Int {
    let typed = max(0, min(typedVisits, visits))
    let link = max(0, visits - typed)
    let weighted = Double(typed) * typedWeight + Double(link) * linkWeight
    let factor = recencyFactor(ageSeconds: now.timeIntervalSince(lastVisit))
    return Int((weighted * factor).rounded())
  }

  /// Map a raw `score` to a bounded ranking contribution the URL-bar
  /// ranker adds on top of the match-quality score. The bucket ceiling
  /// lets a frequently-visited page outrank a stronger-matching but
  /// rarely-visited one — so results feel ordered by how often the
  /// user goes somewhere — while capping the contribution so a runaway
  /// visit count can't bury every fresh match.
  public static func rankingContribution(raw: Int) -> Int {
    switch raw {
    case ..<1: return 0
    case 1..<10: return 100
    case 10..<50: return 200
    case 50..<150: return 300
    default: return 400
    }
  }
}
