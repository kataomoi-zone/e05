import Foundation

/// Represents a pane's address (URL). Determines content type via scheme routing.
///
/// Supported schemes:
/// - `e05://terminal` — terminal pane
/// - `e05://settings` — settings pane (future)
/// - `https://...`, `http://...` — browser pane
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

        // Bare hostname/path → default to https
        return PaneAddress("https://" + trimmed)
    }

    /// Whether navigating from one address to another requires content type change.
    public func requiresContentSwitch(to other: PaneAddress) -> Bool {
        kind != other.kind
    }
}
