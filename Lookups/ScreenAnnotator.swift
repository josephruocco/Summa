import Foundation
import CoreGraphics

// MARK: - Screen-passage premium annotator (live app)
//
// The CLI premium pipeline (GutenbergTest/PremiumAnnotator) works on clean
// book text with full-chapter context and character-offset anchors. The live
// app has none of that: it sees only the OCR'd contents of whatever is
// currently on screen, and every annotation must resolve to a screen
// rectangle to be drawn.
//
// This is the app-shaped version: reconstruct the visible text from OCR
// tokens, make ONE viewport-scoped LLM call (no full-chapter context, no
// callbacks to unseen text, no two-pass critique -- latency has to stay
// livable while someone reads), then map each returned anchor back onto the
// OCR token rectangles it covers. Results are cached by a hash of the
// visible text so scrolling back to a screen you've already read is free.

struct ScreenAnnotation: Sendable {
    let surface: String   // the actual OCR text the anchor matched, for display
    let type: String      // allusion | context | philology | interpretation
    let note: String
    let rect: CGRect      // overlay-local, top-left origin
}

private struct RawAnnotation: Codable {
    let anchor: String
    let type: String
    let note: String
}

enum ScreenAnnotator {

    // Feature settings, stored in UserDefaults so the setting survives launches
    // and (for the API key) so a shipped build works without a dev .env.
    static let apiKeyDefaultsKey = "summa.anthropicAPIKey"
    static let modelDefaultsKey  = "summa.annotationModel"
    static let defaultModel = "claude-sonnet-4-6"

    static func apiKey() -> String? {
        if let k = UserDefaults.standard.string(forKey: apiKeyDefaultsKey),
           !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return k.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Dev fallback only: set when launched from a shell that exported it.
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty {
            return env
        }
        return nil
    }

    static var hasAPIKey: Bool { apiKey() != nil }

    private static var model: String {
        UserDefaults.standard.string(forKey: modelDefaultsKey) ?? defaultModel
    }

    // Don't spend a call on a nearly-empty screen (menus, chrome, a few stray
    // OCR words). A real paragraph of prose is well above this.
    private static let minWords = 20

    // MARK: - Response cache (keyed by normalized visible text)

    private final class Cache: @unchecked Sendable {
        private var store: [Int: [RawAnnotation]] = [:]
        private var order: [Int] = []
        private let lock = NSLock()
        private let cap = 40

        func get(_ key: Int) -> [RawAnnotation]? {
            lock.lock(); defer { lock.unlock() }
            return store[key]
        }
        func put(_ key: Int, _ value: [RawAnnotation]) {
            lock.lock(); defer { lock.unlock() }
            if store[key] == nil {
                order.append(key)
                if order.count > cap, let evict = order.first {
                    order.removeFirst()
                    store[evict] = nil
                }
            }
            store[key] = value
        }
    }
    private static let cache = Cache()

    // MARK: - Public entry

    static func annotate(tokens: [OCRToken], overlaySize: CGSize, bookContext: String?) async -> [ScreenAnnotation] {
        let stream = readingOrderStream(tokens: tokens, overlaySize: overlaySize)
        guard stream.count >= minWords else { return [] }

        let visibleText = stream.map(\.text).joined(separator: " ")
        let cacheKey = normalize(visibleText).hashValue

        let raw: [RawAnnotation]
        if let cached = cache.get(cacheKey) {
            raw = cached
        } else {
            guard let fetched = await requestAnnotations(visibleText: visibleText, bookContext: bookContext) else {
                return []
            }
            cache.put(cacheKey, fetched)
            raw = fetched
        }

        return raw.compactMap { mapToScreen($0, stream: stream) }
    }

    // MARK: - Reading-order token stream

    private struct Tok { let text: String; let rect: CGRect }

    private static func readingOrderStream(tokens: [OCRToken], overlaySize: CGSize) -> [Tok] {
        let toks: [Tok] = tokens.compactMap { t in
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 1 else { return nil }
            let rect = OCR.normToRectInOverlay_TopLeftOrigin(t.rectNorm, overlaySize: overlaySize)
            return Tok(text: text, rect: rect)
        }
        // Same reading-order sort HighlightEngine uses: top-to-bottom rows,
        // left-to-right within a row (6pt row tolerance).
        return toks.sorted {
            if abs($0.rect.midY - $1.rect.midY) > 6 { return $0.rect.midY < $1.rect.midY }
            return $0.rect.minX < $1.rect.minX
        }
    }

    // MARK: - Anchor -> screen rect mapping

    private static func mapToScreen(_ ann: RawAnnotation, stream: [Tok]) -> ScreenAnnotation? {
        guard AnnotationCategory(rawValue: ann.type) != nil else { return nil }
        let anchorWords = normalize(ann.anchor).split(separator: " ").map(String.init)
        guard !anchorWords.isEmpty else { return nil }

        let normTokens = stream.map { normalize($0.text) }
        guard let range = findWordRun(anchorWords, in: normTokens) else { return nil }

        // Long anchors (a whole clause) would union into a giant box spanning
        // several lines. Draw only the first line of the matched run so the
        // highlight stays tight; the note still covers the full idea.
        let runTokens = Array(stream[range])
        let firstLineY = runTokens.first!.rect.midY
        let firstLine = runTokens.filter { abs($0.rect.midY - firstLineY) <= 6 }
        let rect = firstLine.map(\.rect).reduce(CGRect.null) { $0.union($1) }
        guard !rect.isNull else { return nil }

        let surface = firstLine.map(\.text).joined(separator: " ")
        return ScreenAnnotation(surface: surface, type: ann.type, note: ann.note, rect: rect)
    }

    // Finds the first contiguous token run whose normalized text matches the
    // anchor word sequence. Tolerant of trailing punctuation the OCR/model may
    // disagree on; falls back to a looser prefix match on the last word.
    private static func findWordRun(_ anchor: [String], in tokens: [String]) -> ClosedRange<Int>? {
        guard tokens.count >= anchor.count else { return nil }
        for start in 0...(tokens.count - anchor.count) {
            var ok = true
            for k in 0..<anchor.count {
                let tok = tokens[start + k]
                let aw = anchor[k]
                if tok == aw { continue }
                // last anchor word may be truncated differently (possessives, punctuation)
                if k == anchor.count - 1, tok.hasPrefix(aw) || aw.hasPrefix(tok) { continue }
                ok = false
                break
            }
            if ok { return start...(start + anchor.count - 1) }
        }
        return nil
    }

    // MARK: - Normalization

    private static func normalize(_ s: String) -> String {
        var out = s.lowercased()
        for (from, to) in [("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{2014}", " "), ("\u{2013}", " ")] {
            out = out.replacingOccurrences(of: from, with: to)
        }
        // Strip everything but letters, digits, apostrophes and spaces, then
        // collapse whitespace. Punctuation is where OCR and the model most
        // often disagree, so dropping it makes matching robust.
        let allowed = out.unicodeScalars.map { sc -> Character in
            if CharacterSet.alphanumerics.contains(sc) || sc == "'" || sc == " " { return Character(sc) }
            return " "
        }
        return String(allowed).split(separator: " ").joined(separator: " ")
    }

    // MARK: - LLM call

    private static func requestAnnotations(visibleText: String, bookContext: String?) async -> [RawAnnotation]? {
        guard let apiKey = apiKey(),
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }

        let sourceLine = bookContext.map { "Source (for your reference only): \($0)\n\n" } ?? ""
        let prompt = """
        You are an editor annotating literature for an intelligent, well-read general reader, in the manner of a Norton Critical Edition.

        \(sourceLine)The text below is what is currently visible on the reader's screen: a partial view of a longer work, captured by OCR. It may begin or end mid-sentence and contain minor OCR errors. Annotate only what is fully visible here. Do not reference earlier or later parts of the work you cannot see.

        <screen>
        \(visibleText)
        </screen>

        Return a JSON array. Each element:
        {"anchor": "<a short exact substring copied from the text above>", "type": "<allusion|context|philology|interpretation>", "note": "<= 45 words"}

        Types:
        - allusion: a biblical, classical, literary, or mythological source.
        - context: a historical, period, nautical, or ethnographic fact needed to parse the passage.
        - philology: an archaic or shifted word meaning, or an etymology, where it carries the sentence.
        - interpretation: a critical reading, framed as a reading and not a fact. At most one.

        Rules:
        - Annotate only what a smart, well-read non-specialist would genuinely miss. Never define common words. Never restate the text. Never summarize plot.
        - Be selective: at most roughly one annotation per two sentences. Zero annotations is a correct, valid answer for plain text. Do not pad.
        - The anchor must be copied verbatim from the text so it can be located on screen, and must be SHORT: a single word or a short phrase, never a whole sentence.
        - One annotation per distinct reference, each anchored to the specific named thing itself -- the exact title, name, place, or term -- NOT the clause around it. Never bundle several references into a single long anchor. When the text quotes a title, anchor exactly that quoted title.
        - Terse, factual, confident register. No hedging, no throat-clearing.

        For example, in a sentence like: the grand old kings of Pegu placing the title "Lord of the White Elephants" above all their other ascriptions of dominion; and the modern kings of Siam unfurling the same snow-white quadruped
        annotate "Pegu", "Lord of the White Elephants", and "Siam" as three separate entries, each with its own short anchor -- never as one long anchor spanning the whole clause.

        Return only the JSON array, no other text.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1500,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String else { return nil }

        return parseArray(text)
    }

    private static func parseArray(_ text: String) -> [RawAnnotation]? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawAnnotation].self, from: data) else { return nil }
        return raw.filter { !$0.anchor.isEmpty && !$0.note.isEmpty && AnnotationCategory(rawValue: $0.type) != nil }
    }
}

// The five-type editorial taxonomy. Mirrors the CLI's AnnotationCategory but
// the app never produces `callback` (it can't see beyond the current screen);
// it's kept in the enum so a stray callback from the model is still accepted
// rather than dropped.
enum AnnotationCategory: String {
    case allusion, context, callback, philology, interpretation
}
