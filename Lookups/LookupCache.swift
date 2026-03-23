import Foundation

final class LookupCache {
    static let shared = LookupCache()

    private struct CacheStore: Codable {
        var dict: [String: String] = [:]
        var wiki: [String: WikiResult] = [:]
    }

    private var dict: [String: String] = [:]
    private var wiki: [String: WikiResult] = [:]
    private let lock = NSLock()
    private let cacheURL: URL?

    private init() {
        cacheURL = Self.makeCacheURL()
        loadFromDisk()
    }

    func dictionary(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return dict[key]
    }

    func setDictionary(_ key: String, _ val: String) {
        lock.lock()
        dict[key] = val
        let snapshot = CacheStore(dict: dict, wiki: wiki)
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
        let snapshot = CacheStore(dict: dict, wiki: wiki)
        lock.unlock()
        persist(snapshot)
    }

    private func loadFromDisk() {
        guard let cacheURL else { return }
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        guard let decoded = try? JSONDecoder().decode(CacheStore.self, from: data) else { return }

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

    private static func makeCacheURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = appSupport.appendingPathComponent("Summa", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("lookup-cache.json")
    }
}
