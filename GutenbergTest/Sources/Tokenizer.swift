import Foundation

struct Token {
    let raw: String
    let cleaned: String
    let lower: String
    let startsWithUpper: Bool
    let position: Int  // word index in the full text
}

struct AnnotationCandidate {
    let phrase: String
    let kind: Kind
    let position: Int
    let contextBefore: String
    let contextAfter: String

    enum Kind { case vocab, reference }
}

enum Tokenizer {
    private static let stopwords: Set<String> = [
        "the","a","an","and","or","but","if","then","than","so",
        "to","of","in","on","at","for","from","with","without","by","as",
        "is","are","was","were","be","been","being",
        "it","its","this","that","these","those",
        "i","you","he","she","we","they","me","him","her","us","them",
        "my","your","his","their","our",
        "not","no","yes","do","does","did",
        "up","down","over","under","into","out","about",
        // Interjections / exclamations — never proper-noun refs
        "oh","ah","alas","phew","ugh","ha","hey","eh","fie","lo","hark",
        "tut","pshaw","hurrah","whoa","hush","bah","pff","pfft","gosh",
        // Structural document headers — not look-uppable proper nouns
        "chapter","part","section","prologue","epilogue","preface","appendix"
    ]

    private static let phraseConnectors: Set<String> = ["of","the","and","de","la","da","van","von"]

    private static let refCommonAllow: Set<String> = [
        "hook","point","park","square","street","st","avenue","ave","road","rd","lane","ln",
        "river","bay","harbor","harbour","port","fort","mt","mount","lake","island","isles",
        "cove","hill","heights","bridge","pier","wharf","dock","slip"
    ]

    static func tokenize(_ text: String) -> [Token] {
        // Normalize em/en-dashes to spaces so "Lawyer—the" splits into two tokens
        // rather than producing an unfindable hybrid string.
        let expanded = text
            .replacingOccurrences(of: "\u{2014}", with: " ")  // em-dash
            .replacingOccurrences(of: "\u{2013}", with: " ")  // en-dash
        let words = expanded.split(omittingEmptySubsequences: true) { $0.isWhitespace }
        var tokens: [Token] = []
        for (i, word) in words.enumerated() {
            let raw = String(word)
            let cleaned = raw.trimmingCharacters(in: .punctuationCharacters)
                .replacingOccurrences(of: "\u{2019}", with: "'")
            if cleaned.isEmpty || cleaned.count < 2 { continue }
            if cleaned.contains(where: \.isNumber) { continue }
            let lower = cleaned.lowercased()
            let startsUpper = cleaned.unicodeScalars.first.map {
                CharacterSet.uppercaseLetters.contains($0)
            } ?? false
            tokens.append(Token(raw: raw, cleaned: cleaned, lower: lower,
                                startsWithUpper: startsUpper, position: i))
        }
        return tokens
    }

    static func extractCandidates(
        from tokens: [Token],
        commonWords: Set<String>,
        windowSize: Int = 20
    ) -> [AnnotationCandidate] {
        var results: [AnnotationCandidate] = []
        var seenRef = Set<String>()
        var seenVocab = Set<String>()
        var i = 0

        while i < tokens.count {
            let t = tokens[i]

            // --- Proper-noun phrase builder (refs) ---
            if t.startsWithUpper, !stopwords.contains(t.lower) {
                var parts = [t.cleaned]
                var j = i + 1
                while j < tokens.count {
                    let u = tokens[j]
                    let uIsConnector = phraseConnectors.contains(u.lower)
                    let uIsCapitalized = u.startsWithUpper
                    let uIsAllowed = refCommonAllow.contains(u.lower)

                    // Don't extend across sentence boundaries.
                    // "Destiny. For the rest" — "Destiny" should not absorb "For".
                    let prevRaw = tokens[j - 1].raw
                    let prevEndsSentence = prevRaw.last.map { ".?!".contains($0) } ?? false
                    guard !prevEndsSentence else { break }

                    // Treat "and" as a list boundary once we already have a complete
                    // capitalized phrase. This preserves titles like "War and Peace"
                    // (only one capitalized token before "and") but stops runaway
                    // joins like "White Steed and Albatross".
                    if u.lower == "and", parts.count >= 2 {
                        break
                    }

                    // Connectors (of/the/and/…) can extend the phrase when they lead into a
                    // short connector chain that ends in a capitalised token.
                    // This keeps "Lord of the White Elephants" intact while still blocking
                    // runaway prose like "Lawyer the best…".
                    var connectorAllowed = false
                    if uIsConnector {
                        var lookahead = j + 1
                        var chainedConnectors = 0
                        while lookahead < tokens.count && chainedConnectors <= 2 {
                            let v = tokens[lookahead]
                            let prev = tokens[lookahead - 1].raw
                            if prev.last.map({ ".?!".contains($0) }) == true { break }
                            if v.startsWithUpper {
                                connectorAllowed = true
                                break
                            }
                            guard phraseConnectors.contains(v.lower) else { break }
                            chainedConnectors += 1
                            lookahead += 1
                        }
                    }

                    guard uIsCapitalized || connectorAllowed || uIsAllowed else { break }
                    // Don't extend when next token is same word as last
                    if u.lower == parts.last?.lowercased() { break }

                    parts.append(u.cleaned)
                    j += 1
                }

                // Trim trailing connectors
                while let last = parts.last, phraseConnectors.contains(last.lowercased()) {
                    parts.removeLast()
                }

                let phrase = parts.joined(separator: " ")
                let phraseLower = phrase.lowercased()

                if parts.count == 1 {
                    // Single-word: skip if it's a common word (unless proper noun in a
                    // position where it's clearly a name — always upper at sentence start).
                    // Also strip possessive before the check so "Creator's" is caught by
                    // the common-word filter the same way plain "Creator" would be.
                    let basePhraseLower: String
                    if phraseLower.hasSuffix("'s") || phraseLower.hasSuffix("\u{2019}s") {
                        basePhraseLower = String(phraseLower.dropLast(2))
                    } else {
                        basePhraseLower = phraseLower
                    }
                    if (commonWords.contains(phraseLower) || commonWords.contains(basePhraseLower))
                        && !refCommonAllow.contains(basePhraseLower) {
                        i = j; continue
                    }
                    // Skip vocab-suffix words
                    let suffixes = ["able","ible","ing","tion","ness","ment","ous"]
                    if suffixes.contains(where: { phraseLower.hasSuffix($0) }) && phrase.count <= 10 {
                        i = j; continue
                    }
                }

                if seenRef.insert(phraseLower).inserted {
                    let ctx = context(tokens: tokens, pos: i, window: windowSize)
                    results.append(AnnotationCandidate(
                        phrase: phrase,
                        kind: .reference,
                        position: t.position,
                        contextBefore: ctx.before,
                        contextAfter: ctx.after
                    ))
                }
                i = j
                continue
            }

            // --- Vocab (uncommon non-proper words) ---
            let isCommon = commonWords.contains(t.lower)
            let isStop = stopwords.contains(t.lower)
            if !isCommon && !isStop && !t.startsWithUpper && t.cleaned.count >= 4 {
                // Skip obvious suffix classes
                let suffixes9 = ["able","ible","ing"]
                if suffixes9.contains(where: { t.lower.hasSuffix($0) }) && t.cleaned.count <= 9 {
                    i += 1; continue
                }
                if seenVocab.insert(t.lower).inserted {
                    let ctx = context(tokens: tokens, pos: i, window: windowSize)
                    results.append(AnnotationCandidate(
                        phrase: t.cleaned,
                        kind: .vocab,
                        position: t.position,
                        contextBefore: ctx.before,
                        contextAfter: ctx.after
                    ))
                }
            }

            i += 1
        }

        return results
    }

    private static func context(tokens: [Token], pos: Int, window: Int) -> (before: String, after: String) {
        let sentenceEnds: Set<Character> = [".", "!", "?"]

        var beforeStart = max(0, pos - window)
        for p in stride(from: pos - 1, through: max(0, pos - window), by: -1) {
            if tokens[p].raw.last.map({ sentenceEnds.contains($0) }) == true {
                beforeStart = p + 1; break
            }
        }

        var afterEnd = min(tokens.count, pos + window + 1)
        for p in (pos + 1)..<min(tokens.count, pos + window + 1) {
            if tokens[p].raw.last.map({ sentenceEnds.contains($0) }) == true {
                afterEnd = p + 1; break
            }
        }

        let before = tokens[beforeStart..<pos].map(\.cleaned).joined(separator: " ")
        let after = tokens[(pos + 1)..<afterEnd].map(\.cleaned).joined(separator: " ")
        return (before, after)
    }
}
