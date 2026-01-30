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
}

// MARK: - HighlightEngine

final class HighlightEngine {

    // Make this exist so `engine.changeGate...` compiles
    let changeGate = ChangeGate()

    // very small stopword list to avoid highlighting everything
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

    /// MATCHES your call site labels exactly.
    /// Returns overlay-local rects ready for OverlayView + hit-testing in OverlayController.
    func computeHighlights(
        tokens: [OCRToken],
        windowSize: CGSize,
        showVocab: Bool,
        showRefs: Bool
    ) -> (vocab: [HighlightBox], refs: [HighlightBox]) {

        var vocab: [HighlightBox] = []
        var refs: [HighlightBox] = []

        // cap so you don’t flood the overlay
        let maxVocab = 120
        let maxRefs  = 40

        for t in tokens {
            if vocab.count >= maxVocab && refs.count >= maxRefs { break }

            // normalize token text
            let raw = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { continue }

            // make lowercasing the default so you don’t only “work” on capital words
            let cleaned = raw
                .trimmingCharacters(in: .punctuationCharacters)
                .replacingOccurrences(of: "’", with: "'")

            if cleaned.count < 3 { continue }

            // skip numbers / weird tokens
            if cleaned.range(of: #"\d"#, options: .regularExpression) != nil { continue }

            let lower = cleaned.lowercased()
            if stopwords.contains(lower) { continue }

            // Convert normalized Vision rect -> overlay rect.
            // Use whichever helper you already have. This matches the one you showed.
            let rect = OCR.normToRectInOverlay_TopLeftOrigin(t.rectNorm, overlaySize: windowSize)

            // Heuristic:
            // - Vocab = “has a dictionary definition”
            // - Refs  = capitalized-looking token (proper noun-ish)
            if showVocab, vocab.count < maxVocab {
                if let _ = Lookups.definition(for: lower) {
                    vocab.append(HighlightBox(text: cleaned, rect: rect, kind: .vocab))
                    continue
                }
            }

            if showRefs, refs.count < maxRefs {
                // very light “proper noun” heuristic
                let first = cleaned.unicodeScalars.first
                let isCapitalized = first.map { CharacterSet.uppercaseLetters.contains($0) } ?? false
                if isCapitalized {
                    refs.append(HighlightBox(text: cleaned, rect: rect, kind: .reference))
                    continue
                }
            }
        }

        return (vocab, refs)
    }
}
