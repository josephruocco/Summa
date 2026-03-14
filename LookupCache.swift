import Foundation

final class LookupCache {
    static let shared = LookupCache()

    private var dict: [String: String] = [:]
    private var wiki: [String: WikiResult] = [:]
    private let lock = NSLock()

    func dictionary(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return dict[key]
    }

    func setDictionary(_ key: String, _ val: String) {
        lock.lock(); defer { lock.unlock() }
        dict[key] = val
    }

    func wikipedia(_ key: String) -> WikiResult? {
        lock.lock(); defer { lock.unlock() }
        return wiki[key]
    }

    func setWikipedia(_ key: String, _ val: WikiResult) {
        lock.lock(); defer { lock.unlock() }
        wiki[key] = val
    }
}
