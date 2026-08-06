import AppKit
import Sparkle

/// Owns the Sparkle updater and the pending-update flag the menu reads.
///
/// Presentation is split by who asked. A **user-initiated** check gets
/// Sparkle's own window verbatim: the user just asked for this, and the
/// conventional macOS update sheet is the least surprising answer — a
/// bespoke panel would only re-draw what everyone already recognises.
/// A **scheduled** check is the one that would intrude, arriving
/// unannounced while the user is mid-task, so that path is intercepted
/// (`supportsGentleScheduledUpdateReminders`): Sparkle's window is
/// suppressed and the version is recorded instead, which re-titles the
/// menu entry to "Update Available — <version>" until the user acts on
/// it. Choosing the entry then hands control back to the standard flow.
@MainActor
public final class UpdateController: NSObject {
  public static let shared = UpdateController()

  /// Version of an update a scheduled check found and did not present.
  /// `nil` once the user has been shown the standard window, or when
  /// there is nothing waiting.
  public private(set) var pendingUpdateVersion: String?

  /// Built lazily because `SPUStandardUpdaterController` wants `self` as
  /// its user-driver delegate, which is only available post-`super.init`.
  /// `startingUpdater: true` kicks off the scheduler; Sparkle asks the
  /// user for permission to check automatically on first launch.
  private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: self
  )

  override private init() {
    super.init()
  }

  /// Start the update scheduler. Called once at launch — until something
  /// touches `updaterController` the lazy property never materialises and
  /// no background check is scheduled.
  public func start() {
    _ = updaterController
  }

  /// Run a user-initiated check. Clears any pending flag first: from here
  /// the standard window drives the interaction, so leaving the menu
  /// entry re-titled would double up on the same news.
  public func checkForUpdates() {
    pendingUpdateVersion = nil
    updaterController.checkForUpdates(nil)
  }
}

extension UpdateController: SPUStandardUserDriverDelegate {
  public nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  /// Suppress Sparkle's window for scheduled checks. Returning `false`
  /// hands presentation to us, and ``standardUserDriverWillHandleShowingUpdate``
  /// records what to advertise.
  public nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
    _ update: SUAppcastItem,
    andInImmediateFocus immediateFocus: Bool
  ) -> Bool {
    false
  }

  public nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate update: SUAppcastItem,
    state: SPUUserUpdateState
  ) {
    // Only the suppressed (scheduled) case needs recording — when Sparkle
    // handles the display there is nothing for the menu to advertise.
    guard !handleShowingUpdate else { return }
    let version = update.displayVersionString
    Task { @MainActor in
      UpdateController.shared.pendingUpdateVersion = version
    }
  }
}
