import BiblioCore
import CryptoKit
import Foundation
import Observation

/// What one card borrowed before, from its borrowing history: libbiblio's index
/// (core/src/borrowed.zig), synced in the background through the shared throttle and kept in a
/// protected file that stays on this device. Nothing is kept while the library's borrowing
/// history is off.
@Observable
final class BorrowedIndex {
    /// The patron borrowed this item, or this work in another format.
    struct Match: Hashable {
        var sameFormat: Bool
        /// The borrowed format's code.
        var format: String
        /// Times borrowed in that format.
        var count: Int
        var lastCheckout: String?
        var lastReturned: String?
    }

    let subdomain: String
    let username: String

    @ObservationIgnored private let index = CoreIndex()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    /// Entries indexed, and the history's size as the library last reported it.
    private(set) var fetched = 0
    private(set) var total = 0
    /// Every page fetched once: matches are complete, and "Not Borrowed" is offered.
    private(set) var isComplete = false
    private(set) var isSyncing = false
    /// Changes with the matches, so rows showing them update.
    private(set) var generation: UInt64 = 0

    init(subdomain: String, username: String) {
        self.subdomain = subdomain
        self.username = username
    }

    var pointer: OpaquePointer { index.pointer }

    // MARK: Syncing

    /// After signing in: forgets everything when the library keeps no history, else loads the
    /// saved index and brings it up to date.
    func start(client: BiblioClient, historyEnabled: Bool?) {
        guard historyEnabled != false else {
            clear()
            return
        }
        loadIfNeeded()
        sync(client: client)
    }

    /// Fetches what's new (or, the first time, every page, resuming where it stopped).
    func sync(client: BiblioClient) {
        loadIfNeeded()
        run(from: biblio_borrowed_index_begin_sync(pointer), client: client)
    }

    /// Refresh Borrowing History: forgets the index and fetches it all again.
    func rebuild(client: BiblioClient) {
        loadIfNeeded()
        let page = biblio_borrowed_index_rebuild(pointer)
        save()
        refresh()
        // 0: a sync already running carries on from page 1.
        run(from: page, client: client)
    }

    /// Borrowing history turned off, or the card signed out: nothing stays on the device.
    func clear() {
        syncTask?.cancel()
        syncTask = nil
        biblio_borrowed_index_clear(pointer)
        loaded = true
        Self.deleteFile(subdomain: subdomain, username: username)
        refresh()
    }

    private func run(from first: Int64, client: BiblioClient) {
        guard first > 0 else { refresh(); return }
        syncTask = Task {
            var page = first
            while page > 0, !Task.isCancelled {
                do {
                    let result = try await client.borrowingHistoryCorePage(page: Int(page))
                    guard !Task.isCancelled else { break }
                    page = biblio_borrowed_index_apply_page(pointer, page, result.pointer)
                    save()
                } catch {
                    biblio_borrowed_index_fail(pointer)
                    page = 0
                }
                refresh()
            }
            syncTask = nil
            refresh()
        }
        refresh()
    }

    private func refresh() {
        let p = biblio_borrowed_index_progress(pointer)
        fetched = Int(p.fetched)
        total = Int(p.total)
        isComplete = p.complete
        isSyncing = p.syncing
        let g = biblio_borrowed_index_generation(pointer)
        if g != generation { generation = g }
    }

    // MARK: Matching

    /// Whether the patron borrowed this item, or the same work in another format.
    func match(_ bib: Bib) -> Match? {
        _ = generation
        guard fetched > 0 else { return nil }
        return Core.withCStrings([bib.id, bib.format, bib.title, bib.primaryAuthor]) { c in
            let r = biblio_borrowed(pointer, c[0], c[1], c[2], c[3])
            guard r.match != BIBLIO_BORROWED_NONE else { return nil }
            return Match(sameFormat: r.match == BIBLIO_BORROWED_SAME, format: string(r.format) ?? "", count: Int(r.count),
                         lastCheckout: string(r.last_checkout), lastReturned: string(r.last_returned))
        }
    }

    // MARK: Storage

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.fileURL(subdomain: subdomain, username: username)) {
            _ = data.withUnsafeBytes { biblio_borrowed_index_import(pointer, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }
        }
        refresh()
    }

    private func save() {
        var len = 0
        guard let bytes = biblio_borrowed_index_export(pointer, &len) else { return }
        defer { biblio_free(bytes) }
        var url = Self.fileURL(subdomain: subdomain, username: username)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try? Data(bytes: bytes, count: len).write(to: url, options: options)
        // The library can always send it again; it needn't leave the device in a backup.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// One file per card, named by a hash so the name doesn't say whose it is.
    private static func fileURL(subdomain: String, username: String) -> URL {
        let digest = SHA256.hash(data: Data("\(subdomain)|\(username)".utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory.appending(path: "Borrowed", directoryHint: .isDirectory)
            .appending(path: "\(digest.prefix(32)).json")
    }

    /// Deletes a card's saved index (signing out, removing a library).
    static func deleteFile(subdomain: String, username: String) {
        try? FileManager.default.removeItem(at: fileURL(subdomain: subdomain, username: username))
    }
}

/// Owns a core index, freed with the model.
private nonisolated final class CoreIndex: @unchecked Sendable {
    let pointer: OpaquePointer

    init() {
        pointer = biblio_borrowed_index_new()
    }

    deinit {
        biblio_borrowed_index_free(pointer)
    }
}
