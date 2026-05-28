import Foundation

/// How a history visit was reached. Mirrors the subset of
/// `WKNavigationType` that matters for ranking plus an explicit
/// `typed` case the URL bar sets for itself (WebKit has no navigation
/// type for "user typed this into the address bar"; a programmatic
/// `load` always surfaces as `.other`).
///
/// Raw values are persisted in `history.visit_type`, so they are
/// fixed: append new cases with new raw values, never renumber.
/// Frecency weighting per transition is layered on in the ranking
/// layer rather than baked in here, keeping this type a pure record
/// of provenance.
public enum VisitTransition: Int, Sendable, Equatable {
  /// User typed (or pasted) the destination into the URL bar.
  case typed = 0
  /// Followed a link on a page.
  case link = 1
  /// Reloaded the current page.
  case reload = 2
  /// Submitted a form.
  case formSubmitted = 3
  /// Moved through session history (back / forward).
  case backForward = 4
  /// Anything else — programmatic loads, session restore, redirects.
  case other = 5
}
