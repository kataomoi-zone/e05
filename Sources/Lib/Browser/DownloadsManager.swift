import AppKit
import WebKit
import os.log

private let logger = Logger(subsystem: "com.kawarimidoll.e05", category: "DownloadsManager")

/// Lifecycle state of a single download. Stored as raw Int in the DB.
public enum DownloadState: Int {
    case downloading = 0
    case completed = 1
    case failed = 2
    case cancelled = 3
    // case paused — reserved for v2 pause/resume support
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

/// Coordinates active `WKDownload` sessions with the persistent
/// `DownloadsStore`. Fires `onUpdate` after every mutation so the UI
/// (future `DownloadsPaneView`) can refresh without polling.
@MainActor
public final class DownloadsManager: NSObject, WKDownloadDelegate {
    private let store: DownloadsStore
    private var downloads: [Download] = []
    /// Maps live WKDownload to its DB id so delegate callbacks can
    /// locate the corresponding record without scanning `downloads`.
    private var activeByWKDownload: [ObjectIdentifier: Int64] = [:]
    /// KVO observations per active download, keyed by id.
    private var progressObservations: [Int64: NSKeyValueObservation] = [:]

    /// Called after any mutation. Listeners re-read via `all()`.
    public var onUpdate: (() -> Void)?

    public init(store: DownloadsStore) {
        self.store = store
        super.init()
        loadFromDB()
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
        for d in downloads where d.state == .downloading {
            d.state = .cancelled
            d.errorMessage = "App was closed during download"
            d.completedAt = Date()
            store.updateState(
                id: d.id, state: d.state.rawValue,
                completedAt: d.completedAt, errorMessage: d.errorMessage
            )
        }
    }

    /// Snapshot of the current download list, ordered newest first.
    public func all() -> [Download] { downloads }

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
        onUpdate?()
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
                self.onUpdate?()
            }
        }
        progressObservations[id] = observation

        onUpdate?()
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
        onUpdate?()
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
        onUpdate?()
    }

    // MARK: - User actions

    /// Cancel an active download. Silently ignored for entries without a
    /// live WKDownload (e.g. records loaded from DB after restart).
    public func cancel(id: Int64) {
        guard let entry = downloads.first(where: { $0.id == id }),
              let wk = entry.wkDownload else { return }
        wk.cancel(nil)  // triggers didFailWithError with NSURLErrorCancelled
    }

    /// Remove an entry from both the list and the DB. Cancels first if
    /// the download is still active so the partial file is cleaned up
    /// by WKDownload before we drop the record.
    public func remove(id: Int64) {
        if let entry = downloads.first(where: { $0.id == id }),
           entry.state == .downloading {
            cancel(id: id)
            return
        }
        downloads.removeAll { $0.id == id }
        store.delete(id: id)
        onUpdate?()
    }

    /// Clear all non-active entries.
    public func clearCompleted() {
        downloads.removeAll { $0.state != .downloading }
        store.deleteCompleted()
        onUpdate?()
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
