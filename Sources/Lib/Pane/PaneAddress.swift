import Foundation

/// Represents a pane's address (URL). Determines content type via scheme routing.
///
/// Supported schemes:
/// - `e05://terminal` — terminal pane
/// - `e05://finder[/absolute-path]` — native file-browser pane. The
///   current working directory travels in the URL path, so the address
///   remains a single source of truth for session persistence, sidebar
///   worklane labels, and URL-bar display; `currentPath` decodes it back
///   into a filesystem path.
/// - `e05://settings` — not a pane: Settings opens as a window
///   (open_settings / ⌘,), so this address falls back to a blank browser
/// - `https://...`, `http://...` — browser pane
///
/// The former `e05://history`, `e05://bookmarks`, and `e05://downloads`
/// addresses have been retired in favour of the sidebar's dedicated
/// modes. Such URLs now resolve to `.unknown` and restoring an old
/// session entry pointing at them lands on a blank browser pane.
public struct PaneAddress: Equatable, Sendable, CustomStringConvertible {
  public let url: URL

  public var description: String { url.absoluteString }

  /// The resolved content kind for this address.
  public var kind: Kind {
    switch url.scheme {
    case Self.internalScheme:
      guard let host = url.host() else { return .unknown }
      switch host {
      case "terminal": return .terminal
      case "finder": return .finder
      case "settings": return .settings
      default: return .unknown
      }
    case "https", "http", "about", Self.extensionScheme:
      return .browser
    default:
      return .unknown
    }
  }

  // MARK: - Content Kind

  public enum Kind: Equatable {
    case terminal
    case browser
    case finder
    case settings
    case unknown
  }

  // MARK: - Init

  public init(_ url: URL) {
    self.url = url
  }

  public init?(_ string: String) {
    // `encodingInvalidCharacters: true` lets users type a URL with
    // raw non-ASCII characters (e.g. `e05://finder/.../日本語フォルダ`)
    // and still have it parse: Foundation percent-encodes the invalid
    // bytes before building the URL. Already-encoded input passes
    // through unchanged, so this keeps backward compatibility with
    // any `%E6…`-style address that lands here from session.json.
    guard let url = URL(string: string, encodingInvalidCharacters: true) else {
      return nil
    }
    self.url = url
  }

  // MARK: - Well-known addresses

  public static let internalScheme = "e05"

  /// Scheme WebKit uses for extension-owned resources, e.g.
  /// `webkit-extension://<uuid>/options.html`. Routed to `.browser`
  /// kind so an `Open Options Page` action can open the page as a
  /// regular browser column; the pane's WKWebView is initialized
  /// from the matching `WKWebExtensionContext.webViewConfiguration`,
  /// which `PaneModel.init` resolves through `ExtensionController`.
  public static let extensionScheme = "webkit-extension"

  public static let terminal = PaneAddress(URL(string: "\(internalScheme)://terminal")!)
  public static let settings = PaneAddress(URL(string: "\(internalScheme)://settings")!)
  /// Blank browser address (no page loaded). Kept as a sentinel so
  /// `PaneModel.isBlank` comparisons stay stable independent of the
  /// user's home URL preference; new-pane creation sites should
  /// reach for ``newPaneHome`` instead so the preference is honoured.
  public static let blankBrowser = PaneAddress(URL(string: "about:blank")!)

  /// Address used when a new browser pane is opened without a target
  /// URL (sidebar `+`, palette `New Browser Pane`, extension fallback,
  /// etc.). Resolves through `PreferencesStore.shared.preferences.homeURL`
  /// at call time so toggling the setting in the Settings window takes
  /// effect on the next new pane without a relaunch. Falls back to
  /// ``blankBrowser`` when the preference is unset or fails to parse.
  @MainActor
  public static var newPaneHome: PaneAddress {
    let home = PreferencesStore.shared.preferences.homeURL ?? ""
    let trimmed = home.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty, let url = URL(string: trimmed) {
      return PaneAddress(url)
    }
    return .blankBrowser
  }

  // MARK: - Finder

  /// Build an `e05://finder<path>` address from an absolute filesystem path.
  /// Empty / non-absolute input falls back to a bare `e05://finder` URL
  /// so the containing pane can substitute the user's home directory.
  ///
  /// `URLComponents` handles percent-encoding automatically, so paths
  /// with spaces, Japanese characters, or other non-ASCII bytes round
  /// trip through `PaneAddress(String)` → `currentPath` without caller
  /// intervention.
  public static func finder(path: String) -> PaneAddress {
    var components = URLComponents()
    components.scheme = internalScheme
    components.host = "finder"
    if path.hasPrefix("/") {
      components.path = path
    }
    // `URLComponents` with scheme + host always produces a valid URL
    // for any String path that starts with `/`; the force-unwrap is
    // safe. The bare `e05://finder` fallback (empty path) is also
    // produced by URLComponents without error.
    return PaneAddress(components.url!)
  }

  /// Filesystem path encoded in this address, percent-decoded.
  /// Returns an empty string for non-finder addresses and for the bare
  /// `e05://finder` root (where the caller should substitute the user's
  /// home directory). The kind guard enforces the contract at the
  /// getter so callers don't accidentally use `/foo` from an
  /// `https://example.com/foo` address as a filesystem path.
  public var currentPath: String {
    guard kind == .finder else { return "" }
    return url.path(percentEncoded: false)
  }

  /// Human-readable rendering of the address for the URL bar.
  ///
  /// Finder addresses decode the path so paths with non-ASCII
  /// characters display as `e05://finder/Users/you/日本語フォルダ`
  /// rather than the percent-encoded `%E6%97%A5%E6%9C%AC…`. All other
  /// kinds fall through to `absoluteString`, which preserves the
  /// existing browser/terminal URL display (browsers historically
  /// surface the percent-encoded form and changing that is out of
  /// scope for the finder work).
  public var displayString: String {
    if kind == .finder && !currentPath.isEmpty {
      return "\(Self.internalScheme)://finder\(currentPath)"
    }
    return url.absoluteString
  }

  private static let allowedSchemes: Set<String> = [
    internalScheme, "https", "http", "about", extensionScheme,
  ]

  /// Parse user input from the URL bar. Adds `https://` if no scheme is present.
  /// Only allows known schemes (e05, https, http). Unknown schemes return nil.
  public static func fromUserInput(_ input: String) -> PaneAddress? {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    // Already has a scheme — validate it
    if trimmed.contains("://") {
      guard let addr = PaneAddress(trimmed),
        let scheme = addr.url.scheme,
        allowedSchemes.contains(scheme)
      else { return nil }
      return addr
    }

    // about: scheme uses "about:blank" format (no "://")
    if trimmed.hasPrefix("about:") {
      return PaneAddress(trimmed)
    }

    // Bare word without dot or slash is not a URL (e.g. "hello", "swift concurrency")
    guard trimmed.contains(".") || trimmed.contains("/") else { return nil }

    // Bare hostname/path → default to https
    return PaneAddress("https://" + trimmed)
  }

  /// Whether navigating from one address to another requires content type change.
  ///
  /// The kind comparison covers terminal/browser/finder rebuilds.
  /// The extension-resource bit covers a subtler case both sides
  /// classify as `.browser`: a `webkit-extension://` URL and a
  /// regular `https://` URL share the kind but are bound to
  /// incompatible `WKWebViewConfiguration`s — extension-hosted panes
  /// are constructed from the context's own configuration, and
  /// loading external content into that webView would mix the
  /// extension's content world / scheme handlers / API into
  /// non-extension origins. Forcing a pane rebuild whenever the
  /// extension boundary is crossed (in either direction) keeps the
  /// configuration distinction load-bearing.
  public func requiresContentSwitch(to other: PaneAddress) -> Bool {
    if kind != other.kind { return true }
    return isExtensionResource != other.isExtensionResource
  }

  /// Whether this address points at extension-owned resources
  /// (`webkit-extension://<uuid>/...`). Drives the
  /// `requiresContentSwitch` extension-boundary check.
  public var isExtensionResource: Bool {
    url.scheme == Self.extensionScheme
  }

  /// Parse user input as a direct-navigable address.
  ///
  /// Accepts two shapes:
  /// 1. Explicit-scheme inputs (`https://…`, `http://…`, `e05://…`,
  ///    `about:…`) that resolve to a known `Kind`.
  /// 2. Bare hostname inputs that *look* like a domain or IP —
  ///    Brave/Chromium behavior, where `httpbin.org` or
  ///    `192.168.1.1:8080` navigates directly while `hello world`
  ///    falls through to search. Heuristic: no whitespace, the
  ///    host portion contains a dot, and the last dot-separated
  ///    label is either 2+ alphabetic characters (TLD-ish) or
  ///    all digits (IPv4 octet).
  ///
  /// This matches Chromium's well-known "omnibox treats
  /// `README.md` as `https://README.md/`" quirk: `.md` is a real
  /// ccTLD and the heuristic can't distinguish filename intent
  /// from hostname intent. The URL bar mitigates this by showing
  /// the search suggestion alongside the Open URL row, so the
  /// user can still pick search explicitly.
  public static func asDirectNavigation(_ input: String) -> PaneAddress? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !trimmed.contains(where: { $0.isWhitespace })
    else { return nil }

    // Explicit-scheme path. `fromUserInput` has already filtered
    // out disallowed schemes (ftp://, javascript://, …), so a nil
    // here means the input doesn't parse as a URL at all and
    // should fall through to search. Kind can still be `.unknown`
    // for an `e05://` URL whose host doesn't map to a pane type
    // (retired addresses, typos) — let those through so the URL
    // bar offers a direct-open row and the pane lands on the
    // blank-browser fallback inside `PaneModel.init(.unknown)`.
    // Silently converting a typed URL to a search query the way a
    // bare word falls through to DuckDuckGo wouldn't match how
    // mainstream browsers treat typed-but-unreachable URLs.
    if trimmed.contains("://") || trimmed.hasPrefix("about:") {
      return fromUserInput(trimmed)
    }

    // Bare hostname path — must plausibly be a domain or IP.
    guard looksLikeHostname(trimmed) else { return nil }
    return fromUserInput(trimmed)
  }

  /// Heuristic: does `input` look like a bare hostname (optionally
  /// with port/path/query)? Called only from `asDirectNavigation`.
  /// Assumes `input` is already trimmed and whitespace-free.
  private static func looksLikeHostname(_ input: String) -> Bool {
    // Strip path/query/fragment to isolate the host[:port] portion.
    let hostAndPort = input.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    // Strip port.
    let host =
      hostAndPort.split(separator: ":", maxSplits: 1).first.map(String.init)
      ?? String(hostAndPort)

    guard host.contains(".") else { return false }
    // Reject leading/trailing dots (`example.`, `.com`) — those
    // are typographically more like a sentence fragment.
    guard !host.hasPrefix("."), !host.hasSuffix(".") else { return false }

    let labels = host.split(separator: ".")
    guard let last = labels.last else { return false }
    let isTLDish = last.count >= 2 && last.allSatisfy(\.isLetter)
    let isIPv4Octet = !last.isEmpty && last.allSatisfy(\.isNumber)
    return isTLDish || isIPv4Octet
  }

  // MARK: - Search

  /// Placeholder substituted with the percent-encoded query when
  /// resolving the user's `searchTemplate` preference. Kept as a
  /// separate constant so the URL bar's "this row is a search"
  /// detection (`isSearchQuery`) and the address builder
  /// (`searchURL`) stay in sync — changing the marker only needs
  /// one edit here.
  private static let searchPlaceholder = "{query}"

  /// Whether `urlString` was produced by ``searchURL(query:)``. URL-bar
  /// UI branches on this to render a magnifying-glass icon for search
  /// rows instead of the search engine's own favicon — so the row
  /// reads as "run a search" rather than "navigate to duckduckgo.com".
  /// Derived from the current `searchTemplate` preference so the
  /// detection tracks template changes without a restart.
  ///
  /// `!prefix.isEmpty` blocks the catastrophic "match every URL"
  /// failure mode that would happen if the template happens to start
  /// with the placeholder.
  @MainActor
  public static func isSearchQuery(urlString: String) -> Bool {
    let template = PreferencesStore.shared.preferences.searchTemplate
    guard let placeholderRange = template.range(of: searchPlaceholder) else {
      return false
    }
    let prefix = template[..<placeholderRange.lowerBound]
    return !prefix.isEmpty && urlString.hasPrefix(prefix)
  }

  /// Build a browser address for a search query using the current
  /// `searchTemplate` preference. Returns `nil` when the template is
  /// malformed (no `{query}` placeholder) or the encoded query fails,
  /// so callers see the same "no search" signal as before regardless
  /// of which engine the user picked.
  @MainActor
  public static func searchURL(query: String) -> PaneAddress? {
    let template = PreferencesStore.shared.preferences.searchTemplate
    guard template.contains(searchPlaceholder) else { return nil }
    // .urlQueryAllowed keeps `+` unencoded, but servers may interpret it as
    // a space (form encoding). Remove `+` so "C++" encodes to "C%2B%2B".
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove("+")
    guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    let urlString = template.replacingOccurrences(of: searchPlaceholder, with: encoded)
    return PaneAddress(urlString)
  }
}
