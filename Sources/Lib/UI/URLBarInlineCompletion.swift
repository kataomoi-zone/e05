import Foundation

/// Computes the inline-autocomplete suffix shown in the URL bar when the
/// top suggestion's host extends what the user has typed — Brave/Safari
/// "origin autofill". The host is offered both as-is and with a leading
/// `www.` stripped, so typing "exa" completes `www.example.com` to
/// `example.com`. The returned suffix preserves the host's original
/// case so the field reads naturally.
///
/// Returns `nil` when no anchored host completion applies: an empty
/// query, a query already carrying a scheme / slash / space (the user
/// is past bare-host typing and into explicit navigation or search), or
/// a host that doesn't strictly extend the query.
public enum URLBarInlineCompletion {
  public static func hostSuffix(forQuery query: String, candidateURL: String) -> String? {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let lowerQuery = trimmed.lowercased()
    // Only complete bare-host typing. Once a scheme, path, or space is
    // present the user has committed to a full URL or a search query,
    // and silently extending it would fight that intent.
    guard !lowerQuery.contains("/"), !lowerQuery.contains(":"), !lowerQuery.contains(" ")
    else { return nil }

    guard let comps = URLComponents(string: candidateURL),
      let host = comps.host, !host.isEmpty,
      // Complete only to an origin root. Filling a deep page's host
      // would point the field at the origin while a different, deeper
      // row stays selected — completion and default match must agree, so
      // the caller (searchSuggestions) floats a matching origin to the
      // top and a deep page simply gets no completion.
      comps.query == nil, comps.fragment == nil,
      comps.path.isEmpty || comps.path == "/"
    else { return nil }
    let lowerHost = host.lowercased()

    // Match against the host as-is and a www-stripped variant; complete
    // from whichever the query is a strict prefix of.
    let wwwStripped = lowerHost.hasPrefix("www.") ? String(lowerHost.dropFirst(4)) : lowerHost
    let displayStripped = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

    for (lower, display) in [(lowerHost, host), (wwwStripped, displayStripped)] {
      if lower.hasPrefix(lowerQuery), lower.count > lowerQuery.count {
        return String(display.dropFirst(lowerQuery.count))
      }
    }
    return nil
  }
}
