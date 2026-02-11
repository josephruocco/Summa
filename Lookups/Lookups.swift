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

        let result =
            dictionaryDefinition(for: w)
            ?? dictionaryDefinition(for: w.lowercased())
            ?? dictionaryDefinition(for: stripPossessive(w))
            ?? dictionaryDefinition(for: stripPossessive(w.lowercased()))

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
