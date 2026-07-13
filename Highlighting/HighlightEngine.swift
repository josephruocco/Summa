import Foundation
import CoreGraphics

// MARK: - HighlightBox

struct HighlightBox: Identifiable, Hashable {
    enum Kind: Hashable {
        case vocab
        case reference
    }

    let id = UUID()
    let text: String
    let rect: CGRect          // overlay-local coords (top-left origin assumed by your drawing)
    let kind: Kind
    let contextBefore: String
    let contextAfter: String

    init(
        text: String,
        rect: CGRect,
        kind: Kind,
        contextBefore: String = "",
        contextAfter: String = ""
    ) {
        self.text = text
        self.rect = rect
        self.kind = kind
        self.contextBefore = contextBefore
        self.contextAfter = contextAfter
    }
}

// Detects vocabulary highlights (rare-ish words that have a dictionary entry).
// Reference highlights used to be produced here too, by a capitalized-phrase
// matcher feeding the legacy keyword-Wikipedia resolver. That resolver is gone;
// references now come exclusively from the premium AI annotator, so this engine
// only handles vocab.
final class HighlightEngine {

    let changeGate = ChangeGate()

    private let stopwords: Set<String> = [
        "the","a","an","and","or","but","if","then","than","so",
        "to","of","in","on","at","for","from","with","without","by","as",
        "is","are","was","were","be","been","being",
        "it","its","this","that","these","those",
        "i","you","he","she","we","they","me","him","her","us","them",
        "my","your","his","their","our",
        "not","no","yes","do","does","did",
        "up","down","over","under","into","out","about"
    ]

    func computeHighlights(
        tokens: [OCRToken],
        windowSize: CGSize,
        showVocab: Bool
    ) -> [HighlightBox] {

        guard showVocab else { return [] }

        var vocab: [HighlightBox] = []

        // Load common-word list (bundle: common_words_en_20k.txt)
        CommonWords.loadIfNeeded()
        let common = CommonWords.set

        // Tight cap = less clutter, more signal.
        let maxVocab = 28
        var seenVocabTerms = Set<String>()

        struct T {
            let idx: Int
            let raw: String
            let cleaned: String
            let lower: String
            let rect: CGRect // overlay rect
        }

        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func cleanToken(_ s: String) -> String {
            normalize(s)
                .trimmingCharacters(in: .punctuationCharacters)
                .replacingOccurrences(of: "’", with: "'")
        }

        func containsDigit(_ s: String) -> Bool {
            s.range(of: #"\d"#, options: .regularExpression) != nil
        }

        // Build enriched token list + overlay rects
        var ts: [T] = []
        ts.reserveCapacity(tokens.count)

        for (i, t) in tokens.enumerated() {
            let raw = normalize(t.text)
            if raw.isEmpty { continue }

            let cleaned = cleanToken(raw)
            if cleaned.isEmpty { continue }
            if cleaned.count < 2 { continue }

            let lower = cleaned.lowercased()
            if containsDigit(cleaned) { continue }

            let rect = OCR.normToRectInOverlay_TopLeftOrigin(t.rectNorm, overlaySize: windowSize)

            ts.append(T(idx: i, raw: raw, cleaned: cleaned, lower: lower, rect: rect))
        }

        // Sort into reading order (top-to-bottom, left-to-right). Assumes top-left origin overlay coords.
        ts.sort {
            if abs($0.rect.midY - $1.rect.midY) > 6 {
                return $0.rect.midY < $1.rect.midY
            }
            return $0.rect.minX < $1.rect.minX
        }

        // ---- Group into lines ----
        var lines: [[T]] = []
        var current: [T] = []
        var currentY: CGFloat? = nil

        for t in ts {
            if current.isEmpty {
                current = [t]
                currentY = t.rect.midY
                continue
            }
            let y = currentY ?? t.rect.midY
            let thresh = max(8, min(18, t.rect.height * 0.8))
            if abs(t.rect.midY - y) <= thresh {
                current.append(t)
                // keep running average for stability
                currentY = (y * CGFloat(current.count - 1) + t.rect.midY) / CGFloat(current.count)
            } else {
                current.sort { $0.rect.minX < $1.rect.minX }
                lines.append(current)
                current = [t]
                currentY = t.rect.midY
            }
        }
        if !current.isEmpty {
            current.sort { $0.rect.minX < $1.rect.minX }
            lines.append(current)
        }

        // Position lookup: t.idx → index in the reading-order ts array, used for context extraction.
        var idxToTsPos: [Int: Int] = [:]
        for (pos, t) in ts.enumerated() { idxToTsPos[t.idx] = pos }

        // Returns surrounding context, bounded by sentence endings (.!?) within a max window.
        // Sentence-scoped context is more coherent than a flat token window.
        func context(aroundTsPos pos: Int, window: Int = 20) -> (before: String, after: String) {
            var beforeStart = max(0, pos - window)
            for p in stride(from: pos - 1, through: max(0, pos - window), by: -1) {
                let r = ts[p].raw
                if r.hasSuffix(".") || r.hasSuffix("!") || r.hasSuffix("?") {
                    beforeStart = p + 1
                    break
                }
            }

            var afterEnd = min(ts.count, pos + window + 1)
            for p in (pos + 1)..<min(ts.count, pos + window + 1) {
                let r = ts[p].raw
                if r.hasSuffix(".") || r.hasSuffix("!") || r.hasSuffix("?") {
                    afterEnd = p + 1
                    break
                }
            }

            let before = ts[beforeStart..<pos].map { $0.cleaned }.joined(separator: " ")
            let after  = ts[(pos + 1)..<afterEnd].map { $0.cleaned }.joined(separator: " ")
            return (before, after)
        }

        // ---- Vocab highlights: definition exists AND "rare-ish" ----
        for line in lines {
            for t in line {
                if vocab.count >= maxVocab { break }

                if t.cleaned.count < 5 { continue }
                if stopwords.contains(t.lower) { continue }
                if common.contains(t.lower) { continue }

                if let _ = Lookups.definition(for: t.lower) {
                    if t.lower.hasSuffix("ly") && t.cleaned.count <= 7 { continue }
                    if t.lower.hasSuffix("ing") && t.cleaned.count <= 9 { continue }
                    if (t.lower.hasSuffix("able") || t.lower.hasSuffix("ible")) && t.cleaned.count <= 9 { continue }
                    if !seenVocabTerms.insert(t.lower).inserted { continue }

                    let (ctxBefore, ctxAfter) = idxToTsPos[t.idx].map { context(aroundTsPos: $0) } ?? ("", "")
                    vocab.append(HighlightBox(text: t.cleaned, rect: t.rect, kind: .vocab, contextBefore: ctxBefore, contextAfter: ctxAfter))
                }
            }
            if vocab.count >= maxVocab { break }
        }

        return vocab
    }
}
