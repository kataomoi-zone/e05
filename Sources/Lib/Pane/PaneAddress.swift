import Foundation

/// Represents a pane's address (URL). Determines content type via scheme routing.
///
/// Supported schemes:
/// - `e05://terminal` — terminal pane
/// - `e05://settings` — settings pane (future)
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
            case "settings": return .settings
            default: return .unknown
            }
        case "https", "http", "about":
            return .browser
        default:
            return .unknown
        }
    }

    // MARK: - Content Kind

    public enum Kind: Equatable {
        case terminal
        case browser
        case settings
        case unknown
    }

    // MARK: - Init

    public init(_ url: URL) {
        self.url = url
    }

    public init?(_ string: String) {
        guard let url = URL(string: string) else { return nil }
        self.url = url
    }

    // MARK: - Well-known addresses

    public static let internalScheme = "e05"

    public static let terminal = PaneAddress(URL(string: "\(internalScheme)://terminal")!)
    public static let settings = PaneAddress(URL(string: "\(internalScheme)://settings")!)
    /// Blank browser address (no page loaded).
    public static let blankBrowser = PaneAddress(URL(string: "about:blank")!)

    private static let allowedSchemes: Set<String> = [internalScheme, "https", "http", "about"]

    /// Parse user input from the URL bar. Adds `https://` if no scheme is present.
    /// Only allows known schemes (e05, https, http). Unknown schemes return nil.
    public static func fromUserInput(_ input: String) -> PaneAddress? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Already has a scheme — validate it
        if trimmed.contains("://") {
            guard let addr = PaneAddress(trimmed),
                  let scheme = addr.url.scheme,
                  allowedSchemes.contains(scheme) else { return nil }
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
    public func requiresContentSwitch(to other: PaneAddress) -> Bool {
        kind != other.kind
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
              !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

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
        let host = hostAndPort.split(separator: ":", maxSplits: 1).first.map(String.init)
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

    /// Default search engine URL template. `%s` is replaced with the percent-encoded query.
    // TODO: make configurable via user config
    private static let searchTemplate = "https://duckduckgo.com/?q=%s"

    /// Build a browser address for a search query using the default search engine.
    public static func searchURL(query: String) -> PaneAddress? {
        // .urlQueryAllowed keeps `+` unencoded, but servers may interpret it as
        // a space (form encoding). Remove `+` so "C++" encodes to "C%2B%2B".
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove("+")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        let urlString = searchTemplate.replacingOccurrences(of: "%s", with: encoded)
        return PaneAddress(urlString)
    }
}
