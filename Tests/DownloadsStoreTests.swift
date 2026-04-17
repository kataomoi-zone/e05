import Foundation
import Testing

@testable import E05Lib

@MainActor
@Suite("DownloadsStore")
struct DownloadsStoreTests {
    @Test("insert and retrieve entries")
    func insertAndAll() {
        let store = DownloadsStore(inMemory: true)
        let id = store.insert(
            url: "https://example.com/file.zip",
            filename: "file.zip",
            destination: "/tmp/file.zip",
            state: DownloadState.downloading.rawValue
        )
        #expect(id > 0)

        let entries = store.all()
        #expect(entries.count == 1)
        #expect(entries[0].url == "https://example.com/file.zip")
        #expect(entries[0].filename == "file.zip")
        #expect(entries[0].state == DownloadState.downloading.rawValue)
        #expect(entries[0].bytesWritten == 0)
        #expect(entries[0].completedAt == nil)
    }

    @Test("updateFilename replaces filename + destination")
    func updateFilename() {
        let store = DownloadsStore(inMemory: true)
        let id = store.insert(
            url: "https://example.com/a", filename: "", destination: "",
            state: DownloadState.downloading.rawValue
        )
        store.updateFilename(id: id, filename: "real.bin", destination: "/tmp/real.bin")

        let entries = store.all()
        #expect(entries.first?.filename == "real.bin")
        #expect(entries.first?.destination == "/tmp/real.bin")
    }

    @Test("updateProgress writes bytes")
    func updateProgress() {
        let store = DownloadsStore(inMemory: true)
        let id = store.insert(
            url: "https://example.com/x", filename: "x", destination: "/tmp/x",
            state: DownloadState.downloading.rawValue
        )
        store.updateProgress(id: id, bytesWritten: 1_024, totalBytes: 10_240)

        let entries = store.all()
        #expect(entries.first?.bytesWritten == 1_024)
        #expect(entries.first?.totalBytes == 10_240)
    }

    @Test("updateState completion sets completedAt and clears error")
    func updateStateCompleted() {
        let store = DownloadsStore(inMemory: true)
        let id = store.insert(
            url: "https://example.com/y", filename: "y", destination: "/tmp/y",
            state: DownloadState.downloading.rawValue
        )
        let completedAt = Date()
        store.updateState(
            id: id, state: DownloadState.completed.rawValue,
            completedAt: completedAt, errorMessage: nil
        )

        let entry = store.all().first
        #expect(entry?.state == DownloadState.completed.rawValue)
        #expect(entry?.completedAt != nil)
        #expect(entry?.errorMessage == nil)
    }

    @Test("updateState failure stores errorMessage")
    func updateStateFailed() {
        let store = DownloadsStore(inMemory: true)
        let id = store.insert(
            url: "https://example.com/z", filename: "z", destination: "/tmp/z",
            state: DownloadState.downloading.rawValue
        )
        store.updateState(
            id: id, state: DownloadState.failed.rawValue,
            completedAt: Date(), errorMessage: "Network error"
        )

        let entry = store.all().first
        #expect(entry?.state == DownloadState.failed.rawValue)
        #expect(entry?.errorMessage == "Network error")
    }

    @Test("delete removes specific entry")
    func delete() {
        let store = DownloadsStore(inMemory: true)
        let id1 = store.insert(
            url: "https://a/1", filename: "1", destination: "/tmp/1",
            state: DownloadState.completed.rawValue
        )
        _ = store.insert(
            url: "https://a/2", filename: "2", destination: "/tmp/2",
            state: DownloadState.completed.rawValue
        )
        store.delete(id: id1)

        let entries = store.all()
        #expect(entries.count == 1)
        #expect(entries.first?.filename == "2")
    }

    @Test("deleteCompleted removes non-active entries only")
    func deleteCompletedPreservesDownloading() {
        let store = DownloadsStore(inMemory: true)
        _ = store.insert(
            url: "https://a/active", filename: "a", destination: "/tmp/a",
            state: DownloadState.downloading.rawValue
        )
        _ = store.insert(
            url: "https://a/done", filename: "d", destination: "/tmp/d",
            state: DownloadState.completed.rawValue
        )
        _ = store.insert(
            url: "https://a/fail", filename: "f", destination: "/tmp/f",
            state: DownloadState.failed.rawValue
        )
        _ = store.insert(
            url: "https://a/cancel", filename: "c", destination: "/tmp/c",
            state: DownloadState.cancelled.rawValue
        )

        store.deleteCompleted()

        let entries = store.all()
        #expect(entries.count == 1)
        #expect(entries.first?.state == DownloadState.downloading.rawValue)
    }

    @Test("all is ordered by startedAt descending")
    func orderedByStartedAtDesc() {
        let store = DownloadsStore(inMemory: true)
        _ = store.insert(
            url: "https://a/1", filename: "1", destination: "/tmp/1",
            state: DownloadState.completed.rawValue
        )
        Thread.sleep(forTimeInterval: 0.01)
        _ = store.insert(
            url: "https://a/2", filename: "2", destination: "/tmp/2",
            state: DownloadState.completed.rawValue
        )

        let entries = store.all()
        #expect(entries.count == 2)
        #expect(entries[0].filename == "2")
        #expect(entries[1].filename == "1")
    }
}

@MainActor
@Suite("DownloadsManager")
struct DownloadsManagerHelperTests {
    @Test("sanitize strips path separators")
    func sanitizePathSeparators() {
        #expect(DownloadsManager.sanitize(filename: "a/b/c.txt") == "a_b_c.txt")
        #expect(DownloadsManager.sanitize(filename: "..\\evil.exe") == ".._evil.exe")
    }

    @Test("sanitize replaces empty and dot-only names")
    func sanitizeFallback() {
        #expect(DownloadsManager.sanitize(filename: "").hasPrefix("download-"))
        #expect(DownloadsManager.sanitize(filename: ".").hasPrefix("download-"))
        #expect(DownloadsManager.sanitize(filename: "..").hasPrefix("download-"))
        #expect(DownloadsManager.sanitize(filename: "   ").hasPrefix("download-"))
    }

    @Test("sanitize strips null bytes")
    func sanitizeNullByte() {
        #expect(DownloadsManager.sanitize(filename: "ok\0.txt") == "ok.txt")
    }
}
