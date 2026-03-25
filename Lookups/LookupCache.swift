import Foundation

final class LookupCache {
    static let shared = LookupCache()

    // Bump this when scoring logic changes to automatically invalidate stale cached results.
    private static let cacheVersion = 5

    private struct CacheStore: Codable {
        var version: Int = 0
        var dict: [String: String] = [:]
        var wiki: [String: WikiResult] = [:]
    }

    private struct SuppressedLogEntry: Codable {
        var timestampISO8601: String
        var key: String
        var requested: String
        var title: String?
        var score: Double?
        var debug: String?
    }

    private var dict: [String: String] = [:]
    private var wiki: [String: WikiResult] = [:]
    private let lock = NSLock()
    private let cacheURL: URL?
    private let suppressedLogURL: URL?

    private init() {
        cacheURL = Self.makeCacheURL()
        suppressedLogURL = Self.makeSuppressedLogURL()
        loadFromDisk()
    }

    func dictionary(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return dict[key]
    }

    func setDictionary(_ key: String, _ val: String) {
        lock.lock()
        dict[key] = val
        let snapshot = CacheStore(version: Self.cacheVersion, dict: dict, wiki: wiki)
        lock.unlock()
        persist(snapshot)
    }

    func wikipedia(_ key: String) -> WikiResult? {
        lock.lock(); defer { lock.unlock() }
        return wiki[key]
    }

    func setWikipedia(_ key: String, _ val: WikiResult) {
        lock.lock()
        wiki[key] = val
        let snapshot = CacheStore(version: Self.cacheVersion, dict: dict, wiki: wiki)
        lock.unlock()
        persist(snapshot)

        if val.status == .suppressed {
            appendSuppressedLog(
                .init(
                    timestampISO8601: ISO8601DateFormatter().string(from: Date()),
                    key: key,
                    requested: val.requested,
                    title: val.title,
                    score: val.score,
                    debug: val.debug
                )
            )
        }
    }

    private func loadFromDisk() {
        guard let cacheURL else { return }
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        guard let decoded = try? JSONDecoder().decode(CacheStore.self, from: data) else { return }
        // Discard cache if the scoring version has changed
        guard decoded.version == Self.cacheVersion else { return }

        lock.lock()
        dict = decoded.dict
        wiki = decoded.wiki
        lock.unlock()
    }

    private func persist(_ snapshot: CacheStore) {
        guard let cacheURL else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
    }

    private func appendSuppressedLog(_ entry: SuppressedLogEntry) {
        guard let suppressedLogURL else { return }
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }

        let payload = line + "\n"

        if FileManager.default.fileExists(atPath: suppressedLogURL.path),
           let handle = try? FileHandle(forWritingTo: suppressedLogURL) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(payload.utf8))
            return
        }

        try? Data(payload.utf8).write(to: suppressedLogURL, options: [.atomic])
    }

    private static func makeCacheURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = appSupport.appendingPathComponent("Summa", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("lookup-cache.json")
    }

    private static func makeSuppressedLogURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = appSupport.appendingPathComponent("Summa", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("suppressed-annotations.jsonl")
    }
}
