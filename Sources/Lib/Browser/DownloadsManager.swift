import AppKit
import WebKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "DownloadsManager")

/// Lifecycle state of a single download. Stored as raw Int in the DB.
/// New cases must use fresh rawValues — existing rows carry historical
/// numbers and must continue to decode to the same state.
public enum DownloadState: Int {
    case downloading = 0
    case completed = 1
    case failed = 2
    case cancelled = 3
    case paused = 4
}

/// In-memory representation of a single download. The `wkDownload` is
/// `nil` for entries loaded from DB after app relaunch (WKDownload
/// objects don't survive restart), so those entries can be deleted but
/// not cancelled.
@MainActor
public final class Download {
    public let id: Int64
    public let url: String
    public var filename: String
    public var destination: String
    public var state: DownloadState
    public var bytesWritten: Int64
    public var totalBytes: Int64
    public let startedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?
    /// Live handle used to cancel an active download. Released once the
    /// download terminates (completed / failed / cancelled).
    public weak var wkDownload: WKDownload?

    init(
        id: Int64, url: String, filename: String, destination: String,
        state: DownloadState, bytesWritten: Int64, totalBytes: Int64,
        startedAt: Date, completedAt: Date? = nil, errorMessage: String? = nil,
        wkDownload: WKDownload? = nil
    ) {
        self.id = id
        self.url = url
        self.filename = filename
        self.destination = destination
        self.state = state
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
        self.wkDownload = wkDownload
    }
}

/// Opaque handle returned by `DownloadsManager.addListener(_:)`. Pass
/// it back to `removeListener(_:)` to unregister a callback.
public final class DownloadsListenerToken {
    fileprivate let id = UUID()
    fileprivate init() {}
}

/// Coordinates active `WKDownload` sessions with the persistent
/// `DownloadsStore`. Fires registered listeners after every mutation so
/// observers (downloads pane, sidebar badge, future status bar) can
/// refresh without polling. Listeners are multiplexed via
/// `addListener`/`removeListener` — there is no single-slot property.
@MainActor
public final class DownloadsManager: NSObject, WKDownloadDelegate {
    private let store: DownloadsStore
    private var downloads: [Download] = []
    /// Maps live WKDownload to its DB id so delegate callbacks can
    /// locate the corresponding record without scanning `downloads`.
    private var activeByWKDownload: [ObjectIdentifier: Int64] = [:]
    /// KVO observations per active download, keyed by id.
    private var progressObservations: [Int64: NSKeyValueObservation] = [:]
    /// Registered mutation observers, keyed by token id. Insertion order
    /// isn't guaranteed on dispatch since listeners should be independent.
    private var listeners: [UUID: () -> Void] = [:]

    /// Headless WKWebView used solely as the entry point for
    /// `resumeDownload(fromResumeData:)`. It's never attached to a
    /// view hierarchy — the API just requires a WKWebView instance to
    /// kick off the resumed transfer. Using a shared dedicated one
    /// keeps resume independent of whatever BrowserPaneView the
    /// original download came from (that pane may have been closed).
    ///
    /// Configuration inherits `WKWebsiteDataStore.default()` (the
    /// persistent store) so resumed transfers carry the same
    /// cookies / auth tokens the originating pane used. If
    /// BrowserPaneView ever switches to non-persistent or per-profile
    /// data stores, this needs to be revisited — otherwise auth-
    /// gated downloads would 401 after pause.
    private let resumeWebView: WKWebView = {
        let config = WKWebViewConfiguration()
        return WKWebView(frame: .zero, configuration: config)
    }()

    /// Register a mutation observer. Listeners re-read via `all()` or
    /// `activeCount`. Returns a token; pass it to `removeListener(_:)`
    /// to unregister. Listeners are invoked synchronously on the main
    /// actor right after each mutation.
    @discardableResult
    public func addListener(_ block: @escaping () -> Void) -> DownloadsListenerToken {
        let token = DownloadsListenerToken()
        listeners[token.id] = block
        return token
    }

    /// Unregister a previously added listener. No-op if the token is
    /// unknown (already removed or from a different manager).
    public func removeListener(_ token: DownloadsListenerToken) {
        listeners.removeValue(forKey: token.id)
    }

    private func fireListeners() {
        // Snapshot the values before iterating. A listener that
        // registers or unregisters from within its callback would
        // otherwise mutate the dictionary mid-iteration, which Swift's
        // Dictionary traps on. The snapshot cost is negligible for
        // the listener counts we expect (≤ single digits).
        for block in Array(listeners.values) { block() }
    }

    public init(store: DownloadsStore) {
        self.store = store
        super.init()
        loadFromDB()
    }

    // MARK: - Sidecar paths

    /// Directory holding resume-data sidecar files, one per paused
    /// download. `~/.config/e05/resume/<id>.resume`.
    private static var resumeDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/e05/resume")
    }

    /// Sidecar URL for a given download id. Exposed so tests can
    /// verify the path format without running a real download.
    public static func sidecarURL(for id: Int64) -> URL {
        resumeDir.appendingPathComponent("\(id).resume")
    }

    private static func ensureResumeDir() {
        try? FileManager.default.createDirectory(
            at: resumeDir, withIntermediateDirectories: true
        )
    }

    // MARK: - Startup

    /// Load persisted rows from the DB and mark any leftover
    /// `.downloading` entries as cancelled (their WKDownload is gone).
    private func loadFromDB() {
        downloads = store.all().map { entry in
            Download(
                id: entry.id, url: entry.url, filename: entry.filename,
                destination: entry.destination,
                state: DownloadState(rawValue: entry.state) ?? .failed,
                bytesWritten: entry.bytesWritten, totalBytes: entry.totalBytes,
                startedAt: entry.startedAt, completedAt: entry.completedAt,
                errorMessage: entry.errorMessage, wkDownload: nil
            )
        }
        var demotedActive = 0
        for d in downloads where d.state == .downloading {
            d.state = .cancelled
            d.errorMessage = "App was closed during download"
            d.completedAt = Date()
            store.updateState(
                id: d.id, state: d.state.rawValue,
                completedAt: d.completedAt, errorMessage: d.errorMessage
            )
            demotedActive += 1
        }
        // Paused entries need their sidecar to resume. If it was
        // deleted out-of-band (manual rm, disk wipe, etc.) demote
        // the row to failed so the UI reflects reality.
        var demotedPaused = 0
        for d in downloads where d.state == .paused {
            if !FileManager.default.fileExists(atPath: Self.sidecarURL(for: d.id).path) {
                d.state = .failed
                d.errorMessage = "Resume data missing"
                d.completedAt = Date()
                store.updateState(
                    id: d.id, state: d.state.rawValue,
                    completedAt: d.completedAt, errorMessage: d.errorMessage
                )
                demotedPaused += 1
            }
        }
        if demotedActive > 0 || demotedPaused > 0 {
            logger.info(
                "loadFromDB demoted entries: \(demotedActive) downloading→cancelled, \(demotedPaused) paused→failed"
            )
        }
    }

    /// Snapshot of the current download list, ordered newest first.
    public func all() -> [Download] { downloads }

    /// Count of downloads currently in-flight or paused. Iterates `downloads`
    /// without allocating an intermediate array (unlike `all().filter { ... }.count`,
    /// which materializes a temporary Array). O(n) in download count; called
    /// on demand by observers like the sidebar badge.
    public var activeCount: Int {
        downloads.lazy.filter { $0.state == .downloading || $0.state == .paused }.count
    }

    // MARK: - Intake

    /// Adopt a `WKDownload` that just emerged from a navigation
    /// response. Inserts a placeholder record immediately so the UI
    /// can show the new row before `decideDestinationUsing` fires.
    public func adopt(_ wkDownload: WKDownload) {
        wkDownload.delegate = self
        let url = wkDownload.originalRequest?.url?.absoluteString ?? ""
        let id = store.insert(
            url: url, filename: "", destination: "",
            state: DownloadState.downloading.rawValue
        )
        guard id >= 0 else {
            logger.error("Failed to insert download record for URL \(url, privacy: .public)")
            return
        }
        let entry = Download(
            id: id, url: url, filename: "", destination: "",
            state: .downloading, bytesWritten: 0, totalBytes: 0,
            startedAt: Date(), wkDownload: wkDownload
        )
        downloads.insert(entry, at: 0)
        activeByWKDownload[ObjectIdentifier(wkDownload)] = id
        fireListeners()
    }

    // MARK: - WKDownloadDelegate

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        guard let id = activeByWKDownload[ObjectIdentifier(download)],
              let entry = downloads.first(where: { $0.id == id }) else {
            return nil
        }

        // Resumed downloads keep their original destination so WebKit
        // appends partial bytes to the existing file. Skip dedup and
        // totalBytes overwrite — the 206 Partial Content response
        // reports only the remaining chunk, not the full file size.
        if !entry.destination.isEmpty {
            let url = URL(fileURLWithPath: entry.destination)
            let observation = download.progress.observe(
                \.fractionCompleted, options: [.new]
            ) { [weak self, weak entry] progress, _ in
                Task { @MainActor in
                    guard let self, let entry else { return }
                    entry.bytesWritten = Int64(progress.completedUnitCount)
                    if entry.totalBytes == 0 {
                        entry.totalBytes = Int64(progress.totalUnitCount)
                    }
                    self.fireListeners()
                }
            }
            progressObservations[id] = observation
            return url
        }

        let sanitized = Self.sanitize(filename: suggestedFilename)
        let destinationURL = Self.destinationURL(for: sanitized)
        // Surface the final on-disk name (including " (1)" dedup suffix)
        // so what the user sees in the downloads pane matches what
        // Show in Finder reveals.
        let filename = destinationURL.lastPathComponent
        entry.filename = filename
        entry.destination = destinationURL.path
        if response.expectedContentLength > 0 {
            entry.totalBytes = response.expectedContentLength
        }
        store.updateFilename(id: id, filename: filename, destination: destinationURL.path)
        store.updateProgress(
            id: id, bytesWritten: entry.bytesWritten, totalBytes: entry.totalBytes
        )

        // KVO on NSProgress. `fractionCompleted` fires on every byte
        // chunk during active transfer — keep the closure cheap.
        //
        // Fresh downloads let KVO overwrite totalBytes on every tick;
        // NSProgress may update totalUnitCount as the transfer
        // progresses (chunked responses, redirects resolving size),
        // and the latest value is always authoritative. The resumed
        // branch above intentionally guards this because 206 Partial
        // Content reports only the remaining chunk, not the full
        // file, which would otherwise shrink our totalBytes mid-run.
        let observation = download.progress.observe(
            \.fractionCompleted, options: [.new]
        ) { [weak self, weak entry] progress, _ in
            Task { @MainActor in
                guard let self, let entry else { return }
                entry.bytesWritten = Int64(progress.completedUnitCount)
                entry.totalBytes = Int64(progress.totalUnitCount)
                self.fireListeners()
            }
        }
        progressObservations[id] = observation

        fireListeners()
        return destinationURL
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let id = activeByWKDownload.removeValue(forKey: ObjectIdentifier(download)),
              let entry = downloads.first(where: { $0.id == id }) else { return }
        entry.state = .completed
        entry.completedAt = Date()
        entry.wkDownload = nil
        progressObservations.removeValue(forKey: id)?.invalidate()

        // Finalize byte counts. Small files often complete before
        // `fractionCompleted` KVO has a chance to fire (totalUnitCount
        // stays 0 when Content-Length is missing or the transfer is
        // instant), so pulling the progress directly here catches what
        // the observer missed. The destination file stat is a last
        // resort for the "totalUnitCount = 0" case.
        entry.bytesWritten = max(entry.bytesWritten, Int64(download.progress.completedUnitCount))
        entry.totalBytes = max(entry.totalBytes, Int64(download.progress.totalUnitCount))
        if entry.bytesWritten == 0,
           let size = try? FileManager.default.attributesOfItem(atPath: entry.destination)[.size] as? Int64 {
            entry.bytesWritten = size
            if entry.totalBytes == 0 {
                entry.totalBytes = size
            }
        }

        store.updateProgress(
            id: id, bytesWritten: entry.bytesWritten, totalBytes: entry.totalBytes
        )
        store.updateState(
            id: id, state: entry.state.rawValue,
            completedAt: entry.completedAt, errorMessage: nil
        )
        fireListeners()
    }

    public func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData _: Data?
    ) {
        // Intentionally ignore the delegate-supplied resumeData.
        // WebKit also emits resume blobs for transient transport
        // failures (TLS reset, Wi-Fi drop, etc.), but e05 treats
        // "pause" as a user-initiated action only — surfacing a
        // failed download as "paused" without the user asking for
        // it would be confusing. Revisit if auto-recovery lands.
        guard let id = activeByWKDownload.removeValue(forKey: ObjectIdentifier(download)),
              let entry = downloads.first(where: { $0.id == id }) else { return }
        // User-initiated cancel surfaces as NSURLErrorCancelled.
        let isCancelled = (error as NSError).code == NSURLErrorCancelled
        entry.state = isCancelled ? .cancelled : .failed
        entry.completedAt = Date()
        entry.errorMessage = error.localizedDescription
        entry.wkDownload = nil
        progressObservations.removeValue(forKey: id)?.invalidate()
        store.updateState(
            id: id, state: entry.state.rawValue,
            completedAt: entry.completedAt, errorMessage: entry.errorMessage
        )
        fireListeners()
    }

    // MARK: - User actions

    /// Cancel an active download. Silently ignored for entries without a
    /// live WKDownload (e.g. records loaded from DB after restart).
    public func cancel(id: Int64) {
        guard let entry = downloads.first(where: { $0.id == id }),
              let wk = entry.wkDownload else { return }
        wk.cancel(nil)  // triggers didFailWithError with NSURLErrorCancelled
    }

    /// Pause an active download. Saves a sidecar file with the WebKit
    /// resume data so `resume(id:)` can pick up where we left off.
    ///
    /// If the server doesn't advertise Range support, WebKit returns
    /// nil resume data from `cancel()`. We surface that as a plain
    /// cancellation with an explanatory errorMessage so the user
    /// understands why Pause wasn't honored, instead of silently
    /// falling back to "restart from zero on resume".
    public func pause(id: Int64) {
        guard let entry = downloads.first(where: { $0.id == id }),
              entry.state == .downloading,
              let wk = entry.wkDownload else { return }

        // Detach from live tracking BEFORE cancel so the
        // didFailWithError callback that WebKit fires as a side
        // effect of cancellation no-ops (its guard on
        // activeByWKDownload will miss).
        activeByWKDownload.removeValue(forKey: ObjectIdentifier(wk))
        progressObservations.removeValue(forKey: id)?.invalidate()
        entry.wkDownload = nil

        Task { @MainActor in
            let resumeData = await wk.cancel()
            if let data = resumeData {
                Self.ensureResumeDir()
                do {
                    try data.write(to: Self.sidecarURL(for: id), options: .atomic)
                    entry.state = .paused
                    store.updateState(
                        id: id, state: entry.state.rawValue,
                        completedAt: nil, errorMessage: nil
                    )
                } catch {
                    entry.state = .failed
                    entry.errorMessage = "Failed to save resume data: \(error.localizedDescription)"
                    entry.completedAt = Date()
                    store.updateState(
                        id: id, state: entry.state.rawValue,
                        completedAt: entry.completedAt, errorMessage: entry.errorMessage
                    )
                }
            } else {
                entry.state = .cancelled
                entry.errorMessage = "Pause unsupported (server lacks Range support)"
                entry.completedAt = Date()
                store.updateState(
                    id: id, state: entry.state.rawValue,
                    completedAt: entry.completedAt, errorMessage: entry.errorMessage
                )
            }
            fireListeners()
        }
    }

    /// Resume a paused download from its sidecar resume data.
    ///
    /// Flips `state` to `.downloading` synchronously *before* the
    /// async `resumeDownload` call so a second invocation (rapid
    /// Resume clicks, external listener calling back into resume)
    /// finds the entry no longer `.paused` and bails. Without the
    /// guard we'd race two `WKDownload` instances against the same
    /// partial file.
    public func resume(id: Int64) {
        guard let entry = downloads.first(where: { $0.id == id }),
              entry.state == .paused else { return }

        let sidecar = Self.sidecarURL(for: id)
        guard let data = try? Data(contentsOf: sidecar) else {
            // Sidecar missing or unreadable — treat same as
            // loadFromDB's recovery path.
            entry.state = .failed
            entry.errorMessage = "Resume data missing"
            entry.completedAt = Date()
            store.updateState(
                id: id, state: entry.state.rawValue,
                completedAt: entry.completedAt, errorMessage: entry.errorMessage
            )
            fireListeners()
            return
        }

        // Claim the entry synchronously to block re-entry.
        entry.state = .downloading
        entry.errorMessage = nil
        store.updateState(
            id: id, state: entry.state.rawValue,
            completedAt: nil, errorMessage: nil
        )
        fireListeners()

        Task { @MainActor in
            let newDownload = await resumeWebView.resumeDownload(fromResumeData: data)
            newDownload.delegate = self
            activeByWKDownload[ObjectIdentifier(newDownload)] = id
            entry.wkDownload = newDownload
            // Sidecar is "consumed" — once the new download starts,
            // the old resume data is stale (a fresh pause would
            // produce its own). If this resumed transfer itself
            // fails, the user restarts from zero.
            try? FileManager.default.removeItem(at: sidecar)
            // `decideDestinationUsing` (the resumed-path branch) will
            // install a fresh progress observation, so no setup is
            // needed here.
        }
    }

    /// Remove an entry from both the list and the DB. For active
    /// downloads, cancels the transfer (fire-and-forget) before
    /// dropping the record so WebKit tears down its internal state.
    /// The partial file on disk is left alone — cleanup is the user's
    /// responsibility (and what Finder is for).
    public func remove(id: Int64) {
        guard let entry = downloads.first(where: { $0.id == id }) else { return }
        switch entry.state {
        case .downloading:
            if let wk = entry.wkDownload {
                // Detach first so the didFailWithError callback fires
                // by cancel() lookups the entry we're about to drop
                // and no-ops. Same pattern as pause().
                activeByWKDownload.removeValue(forKey: ObjectIdentifier(wk))
                progressObservations.removeValue(forKey: id)?.invalidate()
                entry.wkDownload = nil
                Task { @MainActor in _ = await wk.cancel() }
            }
        case .paused:
            try? FileManager.default.removeItem(at: Self.sidecarURL(for: id))
        case .completed, .failed, .cancelled:
            break
        }
        downloads.removeAll { $0.id == id }
        store.delete(id: id)
        fireListeners()
    }

    /// Clear all non-active entries.
    public func clearCompleted() {
        // Keep both downloading and paused rows — only terminal states
        // (completed / failed / cancelled) are considered "done" and
        // eligible for clearing.
        let retainedStates: Set<DownloadState> = [.downloading, .paused]
        downloads.removeAll { !retainedStates.contains($0.state) }
        store.deleteCompleted()
        fireListeners()
    }

    // MARK: - Helpers

    /// Strip path separators and null bytes from a server-supplied
    /// filename. Falls back to a timestamp-based name if the result is
    /// empty or dot-only.
    static func sanitize(filename: String) -> String {
        let cleaned = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "download-\(Int(Date().timeIntervalSince1970))"
        }
        return cleaned
    }

    /// Build a non-conflicting destination URL in `~/Downloads`. Adds
    /// " (N)" suffix if the filename already exists.
    static func destinationURL(for filename: String) -> URL {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(
            at: downloads, withIntermediateDirectories: true
        )

        let url = downloads.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var counter = 1
        while counter < 1_000 {
            let candidate = ext.isEmpty
                ? downloads.appendingPathComponent("\(stem) (\(counter))")
                : downloads.appendingPathComponent("\(stem) (\(counter)).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
        // Practically unreachable — return the last candidate anyway.
        return url
    }
}
