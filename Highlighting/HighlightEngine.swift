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

    // Words allowed *inside* a capitalized phrase (“West Indies”, “Battery Park”, etc.)
    private let phraseConnectors: Set<String> = ["of","the","and","de","la","da","van","von"]

    // Common words that SHOULD still be allowed as parts of Proper-Noun phrases.
    // (Fixes “Corlears Hook”, “Battery Park”, “Broadway Street”, etc.)
    private let refCommonAllow: Set<String> = [
        "hook","point","park","square","street","st","avenue","ave","road","rd","lane","ln",
        "river","bay","harbor","harbour","port","fort","mt","mount","lake","island","isles",
        "cove","hill","heights","bridge","pier","wharf","dock","slip"
    ]

    func computeHighlights(
        tokens: [OCRToken],
        windowSize: CGSize,
        showVocab: Bool,
        showRefs: Bool
    ) -> (vocab: [HighlightBox], refs: [HighlightBox]) {

        var vocab: [HighlightBox] = []
        var refs: [HighlightBox] = []

        // Load common-word list (bundle: common_words_en_20k.txt)
        CommonWords.loadIfNeeded()
        let common = CommonWords.set

        // Much tighter caps = less clutter, more signal.
        let maxVocab = 28
        let maxRefs  = 30
        var seenVocabTerms = Set<String>()

        struct T {
            let idx: Int
            let raw: String
            let cleaned: String
            let lower: String
            let rect: CGRect // overlay rect
            let startsWithUpper: Bool
            let isConnector: Bool
            let hasDigit: Bool
        }

        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func cleanToken(_ s: String) -> String {
            normalize(s)
                .trimmingCharacters(in: .punctuationCharacters)
                .replacingOccurrences(of: "’", with: "'")
        }

        func startsUpper(_ s: String) -> Bool {
            guard let u = s.unicodeScalars.first else { return false }
            return CharacterSet.uppercaseLetters.contains(u)
        }

        func containsDigit(_ s: String) -> Bool {
            s.range(of: #"\d"#, options: .regularExpression) != nil
        }

        func isLikelyBadSingleReference(_ s: String) -> Bool {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count <= 2 { return true }

            let letters = trimmed.filter(\.isLetter)
            if letters.count <= 2 { return true }

            let uppercaseCount = letters.filter(\.isUppercase).count
            if uppercaseCount == letters.count, letters.count <= 5 {
                return true
            }

            return false
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
            let hasDigit = containsDigit(cleaned)
            if hasDigit { continue }

            let rect = OCR.normToRectInOverlay_TopLeftOrigin(t.rectNorm, overlaySize: windowSize)

            ts.append(T(
                idx: i,
                raw: raw,
                cleaned: cleaned,
                lower: lower,
                rect: rect,
                startsWithUpper: startsUpper(cleaned),
                isConnector: phraseConnectors.contains(lower),
                hasDigit: hasDigit
            ))
        }

        // Sort into reading order (top-to-bottom, left-to-right). Assumes top-left origin overlay coords.
        ts.sort {
            if abs($0.rect.midY - $1.rect.midY) > 6 {
                return $0.rect.midY < $1.rect.midY
            }
            return $0.rect.minX < $1.rect.minX
        }

        // ---- 1) Group into lines ----
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
                // finalize line
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
        // Sentence-scoped context is more coherent for disambiguation than a flat token window.
        func context(aroundTsPos pos: Int, window: Int = 20) -> (before: String, after: String) {
            // Scan backwards for the most recent sentence boundary within the window
            var beforeStart = max(0, pos - window)
            for p in stride(from: pos - 1, through: max(0, pos - window), by: -1) {
                let r = ts[p].raw
                if r.hasSuffix(".") || r.hasSuffix("!") || r.hasSuffix("?") {
                    beforeStart = p + 1
                    break
                }
            }

            // Scan forwards for the next sentence boundary within the window
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

        // Track tokens already consumed by phrase refs so we don't also highlight pieces.
        var consumedTokenIdx = Set<Int>()

        func unionRect(_ rects: [CGRect]) -> CGRect {
            rects.reduce(into: CGRect.null) { acc, r in
                acc = acc.union(r)
            }
        }

        func gapOK(prev: T, next: T) -> Bool {
            let gap = next.rect.minX - prev.rect.maxX
            // Allow small gaps relative to text height (OCR spacing)
            return gap >= -2 && gap <= max(10, prev.rect.height * 0.9)
        }

        func isRefNoise(_ t: T) -> Bool {
            // Always block true stopwords
            if stopwords.contains(t.lower) { return true }
            // Allow common “suffix” words in proper nouns (Hook, Park, Slip, etc.)
            if refCommonAllow.contains(t.lower) { return false }
            // Otherwise, treat “common list” words as noise for refs
            return common.contains(t.lower)
        }

        // ---- 2) Build multi-word phrase refs (e.g., “Corlears Hook”) ----
        if showRefs && refs.count < maxRefs {
            for line in lines {
                var i = 0
                while i < line.count {
                    let t = line[i]

                    // Start only on a capitalized, non-noise token
                    guard t.startsWithUpper, !isRefNoise(t) else {
                        i += 1
                        continue
                    }

                    var j = i
                    var parts: [T] = []
                    var capitalCount = 0

                    while j < line.count {
                        let u = line[j]

                        // spacing constraint (except first token)
                        if !parts.isEmpty {
                            guard gapOK(prev: parts.last!, next: u) else { break }
                        }

                        // Accept: Capitalized tokens, plus small connector words inside the phrase.
                        // Don't extend if the next token is the same word as the last — this
                        // prevents "Christiania: Christiania" (rhetorical repetition) from being
                        // merged into a nonsense two-word phrase that consumes both occurrences.
                        if u.startsWithUpper && !isRefNoise(u) {
                            if u.lower == parts.last?.lower { break }
                            parts.append(u)
                            capitalCount += 1
                            j += 1
                            continue
                        }

                        if u.isConnector, !parts.isEmpty, j + 1 < line.count {
                            // Only keep connector if followed by another capitalized token
                            let v = line[j + 1]
                            if v.startsWithUpper && !isRefNoise(v) && gapOK(prev: u, next: v) && gapOK(prev: parts.last!, next: u) {
                                parts.append(u)
                                j += 1
                                continue
                            }
                        }

                        break
                    }

                    // Emit phrase only if it has 2+ capitalized tokens (true phrase)
                    if capitalCount >= 2, refs.count < maxRefs {
                        let phrase = parts.map { $0.cleaned }.joined(separator: " ")
                        let rect = unionRect(parts.map { $0.rect })
                        let ctxBefore = parts.first.flatMap { idxToTsPos[$0.idx] }.map {
                            ts[max(0, $0 - 15)..<$0].map { $0.cleaned }.joined(separator: " ")
                        } ?? ""
                        let ctxAfter = parts.last.flatMap { idxToTsPos[$0.idx] }.map {
                            ts[($0 + 1)..<min(ts.count, $0 + 16)].map { $0.cleaned }.joined(separator: " ")
                        } ?? ""

                        refs.append(HighlightBox(text: phrase, rect: rect, kind: .reference, contextBefore: ctxBefore, contextAfter: ctxAfter))

                        for p in parts { consumedTokenIdx.insert(p.idx) }
                        i = j
                        continue
                    }

                    i += 1
                }
            }
        }

        // ---- 3) Single-token refs (but stricter than before) ----
        if showRefs && refs.count < maxRefs {
            for line in lines {
                for (k, t) in line.enumerated() {
                    if refs.count >= maxRefs { break }
                    if consumedTokenIdx.contains(t.idx) { continue }
                    guard t.startsWithUpper else { continue }
                    if isRefNoise(t) { continue }

                    let isFirstInLine = (k == 0)
                    let looksNamey = t.cleaned.count >= 6

                    if isFirstInLine && !looksNamey { continue }
                    if isLikelyBadSingleReference(t.cleaned) { continue }

                    let (ctxBefore, ctxAfter) = idxToTsPos[t.idx].map { context(aroundTsPos: $0) } ?? ("", "")
                    refs.append(HighlightBox(text: t.cleaned, rect: t.rect, kind: .reference, contextBefore: ctxBefore, contextAfter: ctxAfter))
                    consumedTokenIdx.insert(t.idx)
                }
                if refs.count >= maxRefs { break }
            }
        }

        // ---- 4) Vocab highlights: definition exists AND “rare-ish” ----
        if showVocab && vocab.count < maxVocab {
            for line in lines {
                for t in line {
                    if vocab.count >= maxVocab { break }
                    if consumedTokenIdx.contains(t.idx) { continue } // don’t vocab-highlight inside phrases/refs

                    // basic filters
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
        }

        return (vocab: vocab, refs: refs)
    }
}
