import AppKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "PopupDiagnostics")

/// Dump the panel state we'd need to classify a "stuck invisible-but-
/// keyed" recurrence on a popup overlay (URL bar suggestion dropdown,
/// find bar, command palette). The three popups share the
/// `child NSPanel + NSGlassEffectView` pattern and have all been
/// observed in the wild rendering at alpha 0 while their key dispatch
/// stayed live. Resetting the alpha unsticks the visual, but the
/// alpha value alone is a tautology — the question is *who* dropped
/// it, and the answers live in the surrounding state:
///
/// - `panel.level`: a competing window pushing past `popUpMenu` would
///   hide the popup behind it; alpha would be irrelevant in that case.
/// - `panel.parent`: a detached child window can sit ordered front in
///   screen space while not following the host through space switches.
/// - `contentView.layer.opacity` vs `presentationLayer.opacity`:
///   AppKit's `animator()` commits CABasicAnimation under the
///   `"opacity"` key on the content layer; if the animation residual
///   stays on the presentation layer the panel can render at 0 while
///   the model alpha is 1.
/// - `hasOpacityAnim`: same idea — if an animation is still attached
///   to the layer at show time, `alphaValue = 1` won't unstick the
///   presentation until we also `removeAnimation(forKey: "opacity")`.
///
/// Call this from the recovery path with the matching scope prefix
/// (`findbar` / `url-suggest` / `palette`); `privacy: .public` is
/// required everywhere because the unified-log default redaction
/// would hide the very values we need.
@MainActor
func logPopupAlphaRecovery(panel: NSPanel, scope: String) {
  let layer = panel.contentView?.layer
  let modelOpacity = layer?.opacity ?? -1
  let presentationOpacity = layer?.presentation()?.opacity ?? -1
  let hasOpacityAnim = layer?.animation(forKey: "opacity") != nil
  let hasParent = panel.parent != nil
  let level = panel.level.rawValue
  logger.warning(
    """
    [popup/\(scope, privacy: .public)] alpha-recovery: this file never \
    writes panel.alphaValue, so the <1 value below points at an external \
    cause (CAAnimation residual, layer invalidation, level override, …) \
    panelAlpha=\(panel.alphaValue, privacy: .public) \
    panelLevel=\(level, privacy: .public) \
    hasParent=\(hasParent, privacy: .public) \
    modelOpacity=\(modelOpacity, privacy: .public) \
    presentationOpacity=\(presentationOpacity, privacy: .public) \
    hasOpacityAnim=\(hasOpacityAnim, privacy: .public)
    """
  )
}
