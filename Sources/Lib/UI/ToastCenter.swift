import AppKit

/// Severity hint that decides default duration and styling for a toast.
public enum ToastStyle {
  /// Successful action feedback — short autodismiss, accent-tinted.
  case info
  /// Failure / blocked-action explanation — longer autodismiss so the
  /// reason can be read, but uses the same accent so the source
  /// workspace stays identifiable.
  case error
}

/// Action-feedback hub. Owns the bottom-center overlay and stages
/// pills with auto-dismiss timers. One instance lives on
/// `PaneContainerViewController` and is invoked from action handlers.
@MainActor
public final class ToastCenter {
  /// Mutable so config plumbing can override without touching call sites.
  public var enabled: Bool = true
  /// Mutable so config plumbing can override without touching call sites.
  public var infoDuration: TimeInterval = 2.0
  /// Mutable so config plumbing can override without touching call sites.
  /// Longer than info so failure reasons stay legible.
  public var errorDuration: TimeInterval = 4.0
  /// Mutable so config plumbing can override without touching call sites.
  /// Oldest is discarded synchronously when a new post would exceed it.
  public var maxStack: Int = 4

  private weak var overlay: ToastOverlayView?
  private var liveTimers: [(pill: ToastPillView, timer: Timer)] = []

  func attach(overlay: ToastOverlayView) {
    self.overlay = overlay
    overlay.center = self
  }

  /// Surface a toast in the active workspace's accent color. Safe to
  /// call from any action handler — drops silently when disabled or
  /// before the overlay attaches.
  public func post(
    _ message: String,
    style: ToastStyle = .info,
    accent: NSColor
  ) {
    guard enabled, let overlay else { return }
    while liveTimers.count >= maxStack {
      let evicted = liveTimers.removeFirst()
      evicted.timer.invalidate()
      // Synchronous discard — fading the bumped pill while stack
      // reflow shoves it upward made it flash near the top edge as
      // the residual alpha caught up with the new position.
      overlay.discard(evicted.pill)
    }
    let pill = ToastPillView(message: message, accent: accent, owner: overlay)
    overlay.push(pill)
    let duration = (style == .error ? errorDuration : infoDuration)
    // `Timer.scheduledTimer` registers in `.default` mode only, so the
    // toast would visibly stall during scrolls / menu tracking
    // (`.eventTracking`). `.common` covers both.
    let timer = Timer(timeInterval: duration, repeats: false) { [weak self, weak pill] _ in
      DispatchQueue.main.async {
        guard let self, let pill else { return }
        if let idx = self.liveTimers.firstIndex(where: { $0.pill === pill }) {
          self.liveTimers.remove(at: idx)
        }
        self.overlay?.remove(pill)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    liveTimers.append((pill, timer))
  }

  /// Click-to-dismiss path. Routes through here (rather than
  /// `overlay.remove` direct) so the matching autodismiss timer is
  /// invalidated and the `liveTimers` entry drops in the same step —
  /// otherwise the timer fires later against an already-detached pill
  /// and the pill instance lingers for the rest of the duration.
  public func dismiss(_ pill: ToastPillView) {
    if let idx = liveTimers.firstIndex(where: { $0.pill === pill }) {
      liveTimers[idx].timer.invalidate()
      liveTimers.remove(at: idx)
    }
    overlay?.remove(pill)
  }
}
