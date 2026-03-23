import Foundation

final class BookAnnotationStore {
    static let shared = BookAnnotationStore()

    struct Pack: Codable {
        struct Entry: Codable {
            var term: String
            var aliases: [String]?
            var kind: String?
            var definition: String?
            var summary: String?
        }

        var sourceMatchers: [String]
        var entries: [Entry]
    }

    struct Match {
        var definition: String?
        var summary: String?
        var debug: String
    }

    private let lock = NSLock()
    private var packs: [Pack] = []
    private var loaded = false

    private init() {}

    func resolve(term: String, kind: HighlightBox.Kind, sourceTitle: String?) -> Match? {
        loadIfNeeded()

        let normalizedSource = normalize(sourceTitle ?? "")
        let normalizedTerm = normalize(term)
        guard !normalizedTerm.isEmpty else { return nil }

        lock.lock()
        let currentPacks = packs
        lock.unlock()

        for pack in currentPacks {
            guard pack.sourceMatchers.isEmpty || pack.sourceMatchers.contains(where: { normalizedSource.contains(normalize($0)) }) else {
                continue
            }

            for entry in pack.entries {
                guard entryKindMatches(entry.kind, kind: kind) else { continue }
                let aliases = (entry.aliases ?? []) + [entry.term]
                if aliases.contains(where: { normalize($0) == normalizedTerm }) {
                    return Match(
                        definition: entry.definition,
                        summary: entry.summary,
                        debug: "book override"
                    )
                }
            }
        }

        return nil
    }

    func directoryURL() -> URL? {
        Self.makeDirectoryURL()
    }

    private func loadIfNeeded() {
        lock.lock()
        let shouldLoad = !loaded
        loaded = true
        lock.unlock()

        guard shouldLoad else { return }
        reload()
    }

    private func reload() {
        let files = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }

        let loadedPacks: [Pack] = files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap(loadPack)

        lock.lock()
        packs = loadedPacks
        lock.unlock()
    }

    private var directories: [URL] {
        [Self.makeWorkspaceDirectoryURL(), Self.makeDirectoryURL()].compactMap { $0 }
    }

    private static func makeDirectoryURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let directory = appSupport
            .appendingPathComponent("Summa", isDirectory: true)
            .appendingPathComponent("book-annotations", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeWorkspaceDirectoryURL() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let directory = cwd.appendingPathComponent("BookAnnotations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return directory
    }

    private func loadPack(at url: URL) -> Pack? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Pack.self, from: data)
    }

    private func entryKindMatches(_ rawKind: String?, kind: HighlightBox.Kind) -> Bool {
        guard let rawKind else { return true }
        switch rawKind.lowercased() {
        case "vocab":
            return kind == .vocab
        case "reference", "ref":
            return kind == .reference
        default:
            return true
        }
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’"))
    }
}
