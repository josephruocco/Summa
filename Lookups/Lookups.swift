import Foundation
import CoreServices // DCSCopyTextDefinition

enum Lookups {

    private static var defCache: [String: String?] = [:]
    private static let lock = NSLock()

    static func definition(for raw: String) -> String? {
        let w = normalize(raw)
        if w.isEmpty { return nil }

        lock.lock()
        if let cached = defCache[w] { lock.unlock(); return cached }
        lock.unlock()

        let result = (
            dictionaryDefinition(for: w)
            ?? dictionaryDefinition(for: w.lowercased())
            ?? dictionaryDefinition(for: stripPossessive(w))
            ?? dictionaryDefinition(for: stripPossessive(w.lowercased()))
        ).flatMap(condenseDefinition)

        lock.lock()
        defCache[w] = result
        lock.unlock()

        return result
    }

    private static func dictionaryDefinition(for term: String) -> String? {
        let cf = term as CFString
        let range = CFRangeMake(0, CFStringGetLength(cf))
        guard let unmanaged = DCSCopyTextDefinition(nil, cf, range) else { return nil }
        return unmanaged.takeRetainedValue() as String
    }

    nonisolated private static func condenseDefinition(_ raw: String) -> String? {
        let cutMarkers = [
            " ORIGIN ",
            " DERIVATIVES ",
            " PHRASES ",
            " PHRASAL VERBS ",
            " USAGE ",
            " SYNONYMS "
        ]

        var text = raw.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        for marker in cutMarkers {
            if let range = text.range(of: marker) {
                text = String(text[..<range.lowerBound])
            }
        }

        if let lastPipe = text.range(of: "|", options: .backwards) {
            text = String(text[lastPipe.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while true {
            if let range = text.range(of: #"^\([^)]*\)\s*"#, options: .regularExpression) {
                text.removeSubrange(range)
                continue
            }
            if let range = text.range(of: #"^\[[^\]]*\]\s*"#, options: .regularExpression) {
                text.removeSubrange(range)
                continue
            }
            if let range = text.range(of: #"^\d+\s*"#, options: .regularExpression) {
                text.removeSubrange(range)
                continue
            }

            let leadingMetadata = [
                "auxiliary verb", "modal verb", "mass noun", "count noun",
                "British English", "North American", "with object", "no object",
                "informal", "formal", "archaic", "dated", "literary", "humorous",
                "noun", "verb", "adjective", "adverb", "pronoun", "preposition",
                "conjunction", "determiner", "exclamation", "predicative"
            ]

            let lowered = text.lowercased()
            let match = leadingMetadata.first {
                let needle = $0.lowercased()
                return lowered.hasPrefix(needle + " ") || lowered == needle
            }
            guard let metadata = match else { break }
            text.removeFirst(metadata.count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let colon = text.firstIndex(of: ":") {
            text = String(text[..<colon])
        }

        if let semicolon = text.firstIndex(of: ";") {
            text = String(text[..<semicolon])
        }

        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return text.isEmpty ? nil : text
    }

    private static func normalize(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        // Helps OCR oddities (diacritics/width variants)
        return t.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    private static func stripPossessive(_ s: String) -> String {
        if s.hasSuffix("'s") { return String(s.dropLast(2)) }
        if s.hasSuffix("’s") { return String(s.dropLast(2)) }
        return s
    }
}
