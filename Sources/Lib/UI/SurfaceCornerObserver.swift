import AppKit
import Foundation

/// Lifetime-scoped observer that keeps a view's `layer?.cornerRadius`
/// synchronised with ``AppMetrics/surfaceCornerRadius``. Owners
/// retain the observer as a stored property; the listener is
/// unregistered automatically when the observer is deallocated.
///
/// This lets every chrome surface (find bar / palette / sidebar /
/// suggestion list / URL dropdown wrapper / pane container) react
/// live to a preset change from the Appearance tab without having to
/// hand-roll listener boilerplate at each call site.
@MainActor
final class SurfaceCornerObserver {
  private let token: UUID

  init(applyingTo view: NSView) {
    view.wantsLayer = true
    Self.apply(to: view)
    self.token = PreferencesStore.shared.addListener { [weak view] _ in
      guard let view else { return }
      Self.apply(to: view)
    }
  }

  /// Push the active corner radius into the target view. Uses
  /// `NSGlassEffectView`'s dedicated `cornerRadius` API when the
  /// view is glass-backed — the glass material's internal halo is
  /// independent of the host layer's `mask`, so layer-only rounding
  /// leaves a faint curve at 0pt. Plain `NSView` chrome (URL bar
  /// dropdown wrapper, pane container) still rounds via
  /// `layer.cornerRadius`.
  private static func apply(to view: NSView) {
    let radius = AppMetrics.surfaceCornerRadius
    if let glass = view as? NSGlassEffectView {
      glass.cornerRadius = radius
    } else {
      view.layer?.cornerRadius = radius
    }
  }

  deinit {
    // `deinit` is nonisolated; hop back to MainActor to unregister
    // because `PreferencesStore.shared` is main-actor isolated.
    let capturedToken = token
    Task { @MainActor in
      PreferencesStore.shared.removeListener(capturedToken)
    }
  }
}
