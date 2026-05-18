import AppKit
import WebKit
import os.log

private let logger = Logger(
  subsystem: LogSubsystem.app, category: "BrowserPaneView+Permissions")

/// Wraps a WebKit `decisionHandler` so the prompt path and the
/// detach-cleanup path can both attempt to resolve it without
/// double-firing. WebKit treats more-than-once or never-fired
/// decision handlers as a contract violation; the resolve-once
/// guard makes the queue safe even when the pane is torn down
/// while a sheet is open.
@MainActor
final class PermissionPromptRequest {
  let host: String
  let kinds: [PermissionKind]
  private var completion: ((WKPermissionDecision) -> Void)?

  init(
    host: String,
    kinds: [PermissionKind],
    completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    self.host = host
    self.kinds = kinds
    self.completion = completion
  }

  /// Resolve exactly once. The first call wins; later calls are
  /// no-ops. Safe to call from both the natural sheet completion
  /// and the detach-drain path.
  func resolve(_ decision: WKPermissionDecision) {
    let pending = completion
    completion = nil
    pending?(decision)
  }
}

extension BrowserPaneView {
  /// Enqueue a permission prompt for `host` / `kinds` and present
  /// it when no other prompt is active. Concurrent requests on the
  /// same pane (e.g. camera and geolocation arriving in the same
  /// tick) wait their turn behind the active sheet rather than
  /// stacking visually identical sheets onto the same window. The
  /// completion always fires exactly once: the natural path runs
  /// it from the sheet's modal callback, and the detach path drains
  /// it as `.deny` (see `drainPermissionPromptsOnDetach`).
  func promptForPermission(
    host: String,
    kinds: [PermissionKind],
    completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
  ) {
    let normalizedHost = host.lowercased()
    guard !normalizedHost.isEmpty, !kinds.isEmpty, self.window != nil else {
      logger.warning(
        "[permissions/prompt] Skipping prompt (no window or empty host); denying"
      )
      completion(.deny)
      return
    }
    let request = PermissionPromptRequest(
      host: normalizedHost, kinds: kinds, completion: completion)
    pendingPermissionPrompts.append(request)
    if pendingPermissionPrompts.count == 1 {
      presentNextPermissionPrompt()
    }
  }

  /// Drain every queued prompt with `.deny` because the pane is
  /// detaching from its host window. The resolve-once guard on
  /// `PermissionPromptRequest` makes the deferred sheet callback a
  /// no-op once we have already replied. The active sheet is sent
  /// through `endSheet(_:returnCode:)` rather than the deprecated
  /// single-argument overload — the modern API tells AppKit to
  /// reclaim the modal dim layer along with the sheet body, while
  /// the legacy overload sometimes left the dim matte stuck to the
  /// parent window after the sheet body had already been removed.
  func drainPermissionPromptsOnDetach() {
    guard !pendingPermissionPrompts.isEmpty || activePermissionAlertWindow != nil
    else { return }
    let pending = pendingPermissionPrompts
    pendingPermissionPrompts.removeAll()
    for request in pending {
      request.resolve(.deny)
    }
    if let alertWindow = activePermissionAlertWindow,
      let parent = alertWindow.sheetParent
    {
      parent.endSheet(alertWindow, returnCode: .cancel)
    }
    activePermissionAlertWindow = nil
  }

  /// Persist the user's choice. `persistent == true` writes through
  /// `PermissionsStore` so the decision survives relaunch; otherwise
  /// the choice lands in the pane's session dict and evaporates with
  /// the pane.
  func recordPermissionDecision(
    host: String,
    kind: PermissionKind,
    state: PermissionState,
    persistent: Bool
  ) {
    let normalized = host.lowercased()
    if persistent {
      PermissionsStore.shared.setState(state, for: normalized, kind: kind)
      return
    }
    var entry = sessionPermissions[normalized] ?? PermissionEntry()
    entry.setState(state, for: kind)
    sessionPermissions[normalized] = entry
  }

  // MARK: - Private

  /// Present the frontmost queued prompt as a Safari-style NSAlert
  /// sheet. The popup accessory picks between "until this pane is
  /// closed" (session-only) and "always" (persisted to
  /// `PermissionsStore`). Both Allow and Don't Allow record so a
  /// site that the user denied once auto-resolves to deny on every
  /// later request.
  private func presentNextPermissionPrompt() {
    guard let request = pendingPermissionPrompts.first,
      let window = self.window
    else {
      // Pane lost its window between enqueue and present; drain.
      drainPermissionPromptsOnDetach()
      return
    }

    let alert = NSAlert()
    alert.messageText = Self.promptMessage(host: request.host, kinds: request.kinds)
    alert.informativeText = Self.promptInformativeText(kinds: request.kinds)
    let allow = alert.addButton(withTitle: "Allow")
    let deny = alert.addButton(withTitle: "Don't Allow")
    allow.keyEquivalent = "\r"
    deny.keyEquivalent = "\u{1b}"

    let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
    popup.addItem(withTitle: "Until this pane is closed")
    popup.addItem(withTitle: "Always")
    popup.selectItem(at: 0)
    alert.accessoryView = popup

    activePermissionAlertWindow = alert.window
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else {
        request.resolve(.deny)
        return
      }
      // The pane may have detached while the sheet was up; the
      // detach drain will already have resolved the request, so
      // these post-sheet writes are guarded by the resolve-once
      // contract anyway.
      let granted = (response == .alertFirstButtonReturn)
      let persistent = popup.indexOfSelectedItem == 1
      let state: PermissionState = granted ? .grant : .deny
      for kind in request.kinds {
        self.recordPermissionDecision(
          host: request.host, kind: kind, state: state, persistent: persistent)
      }
      request.resolve(granted ? .grant : .deny)
      // Pop the just-resolved entry only if it's still at the head;
      // the drain path may already have cleared the queue.
      if self.pendingPermissionPrompts.first === request {
        self.pendingPermissionPrompts.removeFirst()
      }
      if self.activePermissionAlertWindow === alert.window {
        self.activePermissionAlertWindow = nil
      }
      if !self.pendingPermissionPrompts.isEmpty {
        self.presentNextPermissionPrompt()
      }
    }
  }

  // MARK: - Copy

  private static func promptMessage(host: String, kinds: [PermissionKind]) -> String {
    // Notifications use a different verb ("send you" rather than
    // "use your") to match Safari's wording — a notification is
    // pushed at the user, not a device the user holds. The
    // membership check (rather than `kinds == [.notification]`)
    // keeps the push verb correct even if a future caller mixes
    // `.notification` into a combined request; falling through to
    // `capabilityNoun` would otherwise emit "wants to use your
    // notifications", which reads wrong.
    if kinds.contains(.notification) {
      return "\"\(host)\" wants to send you notifications."
    }
    let capability = capabilityNoun(for: kinds)
    return "\"\(host)\" wants to use your \(capability)."
  }

  private static func promptInformativeText(kinds: [PermissionKind]) -> String {
    if kinds.contains(.geolocation) {
      return "Allow this site to know your location?"
    }
    if kinds.contains(.notification) {
      return "Allow this site to show notifications?"
    }
    return "Allow this site to access these devices?"
  }

  /// Build the noun phrase that fills the prompt's "wants to use
  /// your <X>" slot. Geolocation reads "location" instead of a
  /// device list to match Safari's wording. Notifications take a
  /// dedicated branch in `promptMessage` so they don't appear here.
  private static func capabilityNoun(for kinds: [PermissionKind]) -> String {
    if kinds == [.geolocation] { return "location" }
    let names = kinds.map { (k: PermissionKind) -> String in
      switch k {
      case .camera: return "camera"
      case .microphone: return "microphone"
      case .geolocation: return "location"
      case .notification: return "notifications"
      }
    }
    if names.count == 1 { return names[0] }
    if names.count == 2 { return "\(names[0]) and \(names[1])" }
    let head = names.dropLast().joined(separator: ", ")
    return "\(head), and \(names.last ?? "")"
  }
}
