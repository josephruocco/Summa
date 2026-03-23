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

        let candidates = lookupTerms(for: w).compactMap { term -> (String, String)? in
            guard let rawDefinition = dictionaryDefinition(for: term),
                  let condensed = condenseDefinition(rawDefinition) else {
                return nil
            }
            return (term, condensed)
        }

        let result = candidates
            .map { (definition: $0.1, score: scoreDefinition(term: w, query: $0.0, definition: $0.1)) }
            .filter { $0.score >= 0.35 }
            .sorted { lhs, rhs in lhs.score > rhs.score }
            .first?
            .definition

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

    private static func lookupTerms(for word: String) -> [String] {
        let base = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = stripPossessive(base)
        let singular = singularize(stripped)

        var seen = Set<String>()
        return [base, base.lowercased(), stripped, stripped.lowercased(), singular, singular.lowercased()]
            .map(normalize)
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func scoreDefinition(term: String, query: String, definition: String) -> Double {
        let normalizedTerm = normalize(term).lowercased()
        let normalizedQuery = normalize(query).lowercased()
        let loweredDefinition = definition.lowercased()
        let wordCount = definition.split(whereSeparator: \.isWhitespace).count

        var score = 0.0

        if normalizedQuery == normalizedTerm {
            score += 0.28
        } else if normalizedQuery == singularize(normalizedTerm) {
            score += 0.22
        } else {
            score += 0.12
        }

        if (2...12).contains(wordCount) {
            score += 0.24
        } else if wordCount <= 18 {
            score += 0.12
        } else {
            score -= min(0.22, Double(wordCount - 18) * 0.02)
        }

        if loweredDefinition.contains(normalizedTerm) {
            score -= 0.10
        }

        if loweredDefinition.contains("example") || loweredDefinition.contains("especially ") {
            score -= 0.12
        }

        if definition.contains("\"") || definition.contains("'") {
            score -= 0.08
        }

        let uppercaseWords = definition.split(separator: " ").filter {
            guard let first = $0.first else { return false }
            return first.isUppercase
        }.count
        if !term.contains(where: \.isUppercase), uppercaseWords >= 2 {
            score -= 0.16
        }

        if normalizedTerm.count <= 3 {
            score -= 0.12
        }

        return max(0, min(1, score))
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

    private static func singularize(_ s: String) -> String {
        guard s.count > 4 else { return s }
        if s.hasSuffix("ies") { return String(s.dropLast(3)) + "y" }
        if s.hasSuffix("ses") || s.hasSuffix("xes") || s.hasSuffix("zes") { return String(s.dropLast()) }
        if s.hasSuffix("s"), !s.hasSuffix("ss") { return String(s.dropLast()) }
        return s
    }
}
