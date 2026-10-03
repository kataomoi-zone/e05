import Foundation

/// What the system may do to text typed into a page.
///
/// WebKit decides each of these from the host app's defaults and, for
/// the ones left unset, from the user's system-wide Keyboard settings
/// or its own built-in default (`TextCheckerMac.mm`), neither of which
/// leaves a page's text alone the way a browser does.
///
/// Registered once, before the first web view: WebKit reads the keys
/// when it builds its text-checker state and keeps that for the
/// process.
public enum WebTextChecking {
  /// Every substitution off. The spelling underline, which WebKit keeps
  /// off unless asked, on: it marks a word and changes nothing.
  public static func register() {
    UserDefaults.standard.register(defaults: [
      "WebAutomaticQuoteSubstitutionEnabled": false,
      "WebAutomaticDashSubstitutionEnabled": false,
      "WebAutomaticLinkDetectionEnabled": false,
      "WebAutomaticTextReplacementEnabled": false,
      "WebAutomaticSpellingCorrectionEnabled": false,
      "WebSmartInsertDeleteEnabled": false,
      "WebContinuousSpellCheckingEnabled": true,
    ])
  }
}
