import AppKit
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "TerminalSettings")

/// Editor for the user-facing `config.ghostty`. The on-disk file is
/// shared with the libghostty runtime, so a Save here triggers a hot
/// reload that propagates the new config to every live terminal
/// surface without an app restart.
@MainActor
struct TerminalSettingsView: View {
  @State private var bufferText: String = ""
  @State private var savedSnapshot: String = ""
  @State private var observerToken: NSObjectProtocol?
  @State private var showResetConfirm = false
  @State private var diagnostics: [GhosttyConfigDiagnostic] = []
  @State private var incompatibleHits: [GhosttyIncompatibleKeyHit] = []
  @State private var validateTask: Task<Void, Never>?
  /// `true` when the most recent validator run could not be attempted
  /// (libghostty refused to allocate, tempfile write failed, etc.).
  /// The diagnostics panel surfaces this distinctly so the user does
  /// not read an empty diagnostics list as "config is clean".
  @State private var validatorUnavailable: Bool = false
  /// Last `store.write` error, surfaced inline next to Save so a
  /// failed persist does not look like a successful one. Cleared on
  /// the next successful save.
  @State private var saveError: String?

  private let store = GhosttyConfigFileStore.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      editor
      Divider()
      diagnosticsPanel
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear { attach() }
    .onDisappear { detach() }
    .onChange(of: bufferText) { _, newValue in
      scheduleValidate(newValue)
    }
  }

  private var isDirty: Bool { bufferText != savedSnapshot }

  private var header: some View {
    HStack(spacing: 8) {
      Button {
        save()
      } label: {
        Label("Save", systemImage: "checkmark.circle.fill")
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(!isDirty)

      Button {
        reloadFromDisk()
      } label: {
        Label("Reload from Disk", systemImage: "arrow.clockwise")
      }

      Button {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }

      Spacer()

      if let error = saveError {
        Label(error, systemImage: "exclamationmark.octagon.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .help(error)
      } else if isDirty {
        Text("Unsaved changes")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Button(role: .destructive) {
        showResetConfirm = true
      } label: {
        Label("Reset", systemImage: "trash")
      }
      .confirmationDialog(
        "Reset config.ghostty?",
        isPresented: $showResetConfirm,
        titleVisibility: .visible
      ) {
        // Cancel listed first so SwiftUI gives it the Return-default
        // role; Reset stays declared with `.destructive` so it picks
        // up red styling and the OS-level "are you sure" treatment
        // while still requiring a deliberate click.
        Button("Cancel", role: .cancel) {}
        Button("Reset", role: .destructive) { resetToDefaults() }
      } message: {
        Text(
          "The file will be replaced with empty content. ghostty falls back to its built-in defaults."
        )
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var editor: some View {
    TextEditor(text: $bufferText)
      .font(.system(.body, design: .monospaced))
      .autocorrectionDisabled(true)
      .padding(.horizontal, 8)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var diagnosticsPanel: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        if validatorUnavailable {
          Label("Validator unavailable", systemImage: "questionmark.diamond.fill")
            .foregroundStyle(.secondary)
            .font(.callout)
            .help(
              "libghostty could not parse the buffer. The on-screen text was not validated."
            )
        } else if diagnostics.isEmpty && incompatibleHits.isEmpty {
          Label("No issues detected", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.secondary)
            .font(.callout)
        } else {
          ForEach(diagnostics, id: \.self) { diag in
            Label {
              Text(diag.message)
                .font(.callout)
                .textSelection(.enabled)
            } icon: {
              Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            }
          }
          ForEach(incompatibleHits, id: \.self) { hit in
            Label {
              VStack(alignment: .leading, spacing: 2) {
                Text("Line \(hit.lineNumber): `\(hit.key)`")
                  .font(.callout)
                Text(hit.reason)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 180)
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private func attach() {
    let initial = store.read()
    bufferText = initial
    savedSnapshot = initial
    runValidate(initial)
    observerToken = NotificationCenter.default.addObserver(
      forName: GhosttyConfigFileStore.didChangeNotification,
      object: store,
      queue: .main
    ) { _ in
      Task { @MainActor in syncFromStoreIfClean() }
    }
  }

  private func detach() {
    if let token = observerToken {
      NotificationCenter.default.removeObserver(token)
      observerToken = nil
    }
    validateTask?.cancel()
    validateTask = nil
  }

  /// Debounced revalidation. Each keystroke cancels the in-flight
  /// task so the libghostty parser only runs after the user pauses;
  /// 300 ms keeps the editor responsive while a long config (hundreds
  /// of lines) is being edited.
  private func scheduleValidate(_ text: String) {
    validateTask?.cancel()
    validateTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      if Task.isCancelled { return }
      runValidate(text)
    }
  }

  private func runValidate(_ text: String) {
    if let parsed = GhosttyConfigValidator.validate(text) {
      diagnostics = parsed
      validatorUnavailable = false
    } else {
      diagnostics = []
      validatorUnavailable = true
    }
    incompatibleHits = GhosttyIncompatibleKeys.scan(text)
  }

  /// Adopt a fresh on-disk read into the buffer, but only when the
  /// user has no pending edits. Pending edits stay parked so a
  /// concurrent external write does not silently discard typed text;
  /// the Reload from Disk button is the explicit opt-in to overwrite.
  private func syncFromStoreIfClean() {
    guard !isDirty else { return }
    let next = store.read()
    bufferText = next
    savedSnapshot = next
  }

  private func save() {
    // POSIX text-file convention: non-empty files end with a newline.
    // Append one if the user's buffer is missing it so a hand-edit
    // that drops the trailing newline still produces a clean file.
    // Empty buffers stay empty so Reset leaves a 0-byte file rather
    // than a stray newline.
    let normalized: String
    if bufferText.isEmpty || bufferText.hasSuffix("\n") {
      normalized = bufferText
    } else {
      normalized = bufferText + "\n"
    }
    do {
      try store.write(normalized)
      bufferText = normalized
      savedSnapshot = normalized
      saveError = nil
      hotReloadRuntime()
    } catch {
      let description = error.localizedDescription
      logger.error("[terminal-settings] save failed: \(description, privacy: .public)")
      saveError = "Save failed: \(description)"
    }
  }

  private func reloadFromDisk() {
    let next = store.read()
    bufferText = next
    savedSnapshot = next
  }

  private func resetToDefaults() {
    bufferText = ""
    save()
  }

  /// Drive libghostty to re-read the file we just wrote, so every
  /// live terminal pane picks up the edit on the same MainActor
  /// turn. Falls back to a logger.warning when the Settings panel
  /// was opened before the pane container seeded itself (test
  /// harness path) — the disk write still persists.
  private func hotReloadRuntime() {
    guard let app = SettingsWindowController.shared.paneContainer?.ghosttyApp else {
      logger.warning("[terminal-settings] paneContainer is nil; hot reload skipped")
      return
    }
    app.reloadConfigFromDisk()
  }
}
