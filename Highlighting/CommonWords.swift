import Foundation

enum CommonWords {
    private static var loaded = false
    private static var _set: Set<String> = []

    static var set: Set<String> { _set }

    static func loadIfNeeded(resource: String = "common_words_en_20k",
                             ext: String = "txt") {
        guard !loaded else { return }
        loaded = true

        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        let words = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        _set = Set(words)
    }
}
