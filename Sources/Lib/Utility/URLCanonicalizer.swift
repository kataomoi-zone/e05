import Foundation

/// Canonical identity key for a web URL, deciding whether two URLs
/// point at "the same page" for suggestion dedup and open-pane
/// matching. Folds away differences that don't change the
/// destination: scheme (http/https), a leading `www.`, the fragment,
/// trailing slashes, and well-known tracking query parameters
/// (`utm_*`, `fbclid`, …). Remaining query items are sorted so
/// parameter order doesn't split the key. Port is kept — it is part
/// of the page's identity (`localhost:3000` ≠ `localhost:8080`).
///
/// Returns `nil` for inputs that don't parse as an http(s) URL with a
/// host (extension pages, `about:`, garbage); callers fall back to
/// raw-string comparison for those.
public enum URLCanonicalizer {
  /// Exact query parameter names dropped before keying — analytics /
  /// ad-attribution tokens that never change which page is shown.
  private static let trackingParams: Set<String> = [
    "fbclid", "gclid", "dclid", "msclkid", "mc_eid", "mc_cid",
    "igshid", "yclid", "ref_src", "ref_url",
  ]
  /// Query parameter name prefixes dropped before keying.
  private static let trackingPrefixes: [String] = ["utm_"]

  public static func canonicalKey(_ urlString: String) -> String? {
    guard let comps = URLComponents(string: urlString),
      let scheme = comps.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      var host = comps.host?.lowercased(), !host.isEmpty
    else { return nil }

    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    if let port = comps.port { host += ":\(port)" }

    var path = comps.percentEncodedPath
    while path.hasSuffix("/") { path = String(path.dropLast()) }

    let keptItems =
      (comps.queryItems ?? [])
      .filter { item in
        let name = item.name.lowercased()
        if trackingParams.contains(name) { return false }
        if trackingPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
        return true
      }
      .sorted { lhs, rhs in
        lhs.name == rhs.name ? (lhs.value ?? "") < (rhs.value ?? "") : lhs.name < rhs.name
      }
      .map { item in item.value.map { "\(item.name)=\($0)" } ?? item.name }

    let query = keptItems.isEmpty ? "" : "?" + keptItems.joined(separator: "&")
    return "\(host)\(path)\(query)"
  }
}
