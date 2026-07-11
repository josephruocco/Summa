import Foundation

// MARK: - Premium annotation pipeline (ANNOTATION_QUALITY_MODE=premium)
//
// Legacy mode (Wikipedia.planAnnotation) classifies pre-extracted proper-noun
// candidates one at a time. Tokenizer.extractCandidates only ever surfaces
// capitalized phrases, so that gate structurally cannot produce `philology`
// (archaic sense of an ordinary lowercase word) or most `interpretation`
// annotations, no matter how good the downstream prompt is.
//
// Premium mode instead sends a whole paragraph to the model in one shot and
// asks it to both find and classify annotation-worthy spans across the full
// editorial taxonomy, then runs a second "senior editor" pass that critiques
// the first. Legacy mode is untouched; this is an additive path selected by
// ANNOTATION_QUALITY_MODE=premium.

enum AnnotationCategory: String, Codable, CaseIterable {
    case allusion, context, callback, philology, interpretation
}

struct PassageAnnotation: Codable, Sendable, Equatable {
    var anchor: String
    var type: String
    var note: String
    // Populated only by mergeLegacyGrounding, when the legacy per-candidate
    // Wikipedia/gloss planner confidently resolves the same span. Absent
    // (nil) for annotations that came straight from the LLM passage pass.
    var wikipediaTitle: String? = nil
    var wikipediaURL: String? = nil
}

struct TokenUsage: Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(inputTokens: lhs.inputTokens + rhs.inputTokens,
                   outputTokens: lhs.outputTokens + rhs.outputTokens)
    }

    // ponytail: hardcoded Claude Sonnet pricing ($3/M in, $15/M out) as an
    // estimate for the cost-per-chapter logging the spec asks for. Update
    // here if pricing changes; not worth a config file for two numbers.
    var estimatedCostUSD: Double {
        Double(inputTokens) / 1_000_000 * 3.0 + Double(outputTokens) / 1_000_000 * 15.0
    }
}

enum PremiumAnnotator {
    static let model = Wikipedia.envValue("ANNOTATION_MODEL") ?? "claude-sonnet-4-6"

    // ~4 chars/token heuristic (matches the truncation heuristics already
    // used elsewhere in Wikipedia.swift). Below this, inline the full chapter;
    // above it, fall back to the static per-book literary note as a digest.
    private static let inlineChapterCharBudget = 20_000 * 4

    struct AnnotateResult {
        var annotations: [PassageAnnotation]
        var usage: TokenUsage
        // Full annotations, not just counts, so a run's JSON dump can show
        // exactly what the critique pass added or cut and why -- counts alone
        // can't tell you whether a specific expected annotation was ever
        // proposed and then cut, or never proposed at all.
        var addedByCritique: [PassageAnnotation]
        var cutByCritique: [PassageAnnotation]
    }

    static func annotate(
        passage: String,
        chapterText: String,
        bookContext: String,
        literaryNote: String?
    ) async -> AnnotateResult {
        let contextBlock = buildContextBlock(chapterText: chapterText, literaryNote: literaryNote)
        var usage = TokenUsage()

        guard let (firstText, u1) = await callModel(
            firstPassPrompt(passage: passage, contextBlock: contextBlock, bookContext: bookContext)
        ) else {
            return AnnotateResult(annotations: [], usage: usage, addedByCritique: [], cutByCritique: [])
        }
        usage = usage + u1
        let first = parseAnnotationArray(firstText)

        guard let (critiqueText, u2) = await callModel(
            critiquePrompt(passage: passage, contextBlock: contextBlock, bookContext: bookContext, firstPass: first)
        ) else {
            return AnnotateResult(annotations: repairAnchors(first, passage: passage),
                                   usage: usage, addedByCritique: [], cutByCritique: [])
        }
        usage = usage + u2

        let (misses, cuts) = parseCritique(critiqueText)
        let cutAnnotations = first.filter { ann in cuts.contains { $0.lowercased() == ann.anchor.lowercased() } }
        let kept = first.filter { ann in !cuts.contains { $0.lowercased() == ann.anchor.lowercased() } }
        let merged = kept + misses

        return AnnotateResult(
            annotations: repairAnchors(merged, passage: passage),
            usage: usage,
            addedByCritique: misses,
            cutByCritique: cutAnnotations
        )
    }

    // MARK: - Context block (Phase 1: full chapter or digest)

    private static func buildContextBlock(chapterText: String, literaryNote: String?) -> String {
        if chapterText.count <= inlineChapterCharBudget {
            return "Full chapter text (for spotting callbacks to earlier parts of this same chapter):\n\(chapterText)"
        }
        // ponytail: the current fetch pipeline only ever retrieves a single
        // chapter, so there's no prior-chapter text to summarize into a real
        // book digest yet. Fall back to the static per-book literary note
        // (tools/literary_notes.json) as a coarse digest. Upgrade to a
        // generated multi-chapter digest once the pipeline fetches more than
        // one chapter per book.
        let note = literaryNote.map { "Book digest: \($0)" } ?? "Book digest: (none available)"
        return "\(note)\n\n(Chapter too long to inline in full; only the passage below and this digest are available as context.)"
    }

    // MARK: - Prompts (Phase 3: taxonomy + few-shot + schema)

    private static func firstPassPrompt(passage: String, contextBlock: String, bookContext: String) -> String {
        """
        You are an editor preparing a Norton Critical Edition of \(bookContext).
        Your reader is intelligent and well-read but not a specialist in this
        book's period or references — annotate what they would miss, not what
        they'd already catch.

        \(contextBlock)

        <passage>
        \(passage)
        </passage>

        Annotate the passage inside <passage> above — it is the target. The
        surrounding chapter text/digest is context for understanding it, not
        something to annotate itself.

        Return a JSON array. Each element:
        {"anchor": "<exact verbatim substring of the passage>", "type": "<allusion|context|callback|philology|interpretation>", "note": "<= 60 words>"}

        Types:
        - allusion: biblical, classical, literary, or mythological sources.
        - context: historical, period, nautical, or ethnographic facts needed to parse the passage.
        - callback: a reference to an earlier moment in this same book (use the chapter text above).
        - philology: an archaic or shifted word meaning, or etymology, where it carries the sentence.
        - interpretation: a critical reading, explicitly framed as a reading, not a fact. At most 1-2 per passage.

        Rules:
        - Annotate only what a smart, widely-read but non-specialist reader would miss. Never define common words. Never summarize the plot. No annotation should just restate the passage.
        - Density: roughly one annotation per 2-4 sentences on dense, allusion-heavy text; fewer on plain text. Zero annotations on a plain paragraph is a correct, valid output — do not pad to hit a quota.
        - Terse, factual, confident register. No "this suggests that the author may be...", no hedging, no throat-clearing.
        - anchor must be copied verbatim, character-for-character, from the passage.

        Example (a short public-domain passage, not from this book):

        Passage: "It was the best of times, it was the worst of times, it was the age of wisdom, it was the age of foolishness, in the epoch of belief, in the epoch of incredulity."

        [
          {"anchor": "it was the age of wisdom, it was the age of foolishness", "type": "interpretation", "note": "Reading: the unresolved antitheses refuse to pick a single verdict on the era, setting up the novel's argument that revolutionary periods contain their opposites at once rather than in sequence."},
          {"anchor": "epoch", "type": "philology", "note": "From Greek epokhe, \\"a fixed point in time\\" — a scientific/scholarly register raised above the plainer \\"age\\" or \\"time\\" used elsewhere in the sentence."}
        ]

        Return only the JSON array, no other text.
        """
    }

    private static func critiquePrompt(passage: String, contextBlock: String, bookContext: String, firstPass: [PassageAnnotation]) -> String {
        let firstPassJSON = (try? JSONEncoder().encode(firstPass)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        You are the senior editor of a Norton Critical Edition of \(bookContext),
        reviewing a junior editor's annotations of one passage before publication.

        \(contextBlock)

        <passage>
        \(passage)
        </passage>

        Junior editor's annotations:
        \(firstPassJSON)

        List:
        (a) significant allusions, callbacks, or philological points they MISSED — only genuinely valuable additions, same schema as the annotations above.
        (b) annotations that are wrong, obvious, padding, or restate the passage — return just their anchor text so they can be cut.

        Return only this JSON object, no other text:
        {"misses": [{"anchor": "...", "type": "allusion|context|callback|philology|interpretation", "note": "..."}], "cuts": ["anchor text", "..."]}
        """
    }

    // MARK: - Anchor verification/repair

    // Reject/repair any annotation whose anchor isn't a verbatim substring of
    // the passage, so the UI can always highlight what the model claims to.
    // Model output consistently uses straight quotes even when the source
    // passage has curly ones (or vice versa) -- normalize before falling
    // back to a drop, so a correct annotation isn't lost over punctuation
    // style. Substitution is 1-for-1 per Character, so character offsets
    // computed on the normalized string map directly back onto the original.
    private static func normalizeQuotes(_ s: String) -> String {
        let map: [Character: Character] = ["\u{201C}": "\"", "\u{201D}": "\"", "\u{2018}": "'", "\u{2019}": "'"]
        return String(s.map { map[$0] ?? $0 })
    }

    private static func repairAnchors(_ annotations: [PassageAnnotation], passage: String) -> [PassageAnnotation] {
        let normalizedPassage = normalizeQuotes(passage)
        return annotations.compactMap { ann in
            if passage.contains(ann.anchor) { return ann }

            let trimmed = ann.anchor.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.,;:")))
            if !trimmed.isEmpty, passage.contains(trimmed) {
                var repaired = ann
                repaired.anchor = trimmed
                return repaired
            }

            let normalizedAnchor = normalizeQuotes(ann.anchor)
            if !normalizedAnchor.isEmpty, let range = normalizedPassage.range(of: normalizedAnchor) {
                let start = normalizedPassage.distance(from: normalizedPassage.startIndex, to: range.lowerBound)
                let length = normalizedPassage.distance(from: range.lowerBound, to: range.upperBound)
                let lower = passage.index(passage.startIndex, offsetBy: start)
                let upper = passage.index(lower, offsetBy: length)
                var repaired = ann
                repaired.anchor = String(passage[lower..<upper])
                return repaired
            }

            FileHandle.standardError.write("  ! dropped annotation with non-matching anchor: \(ann.anchor)\n".data(using: .utf8)!)
            return nil
        }
    }

    // MARK: - Model call + JSON parsing

    private static func callModel(_ prompt: String) async -> (String, TokenUsage)? {
        guard let apiKey = Wikipedia.envValue("ANTHROPIC_API_KEY"), !apiKey.isEmpty,
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2000,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String else { return nil }

        let usageJSON = json["usage"] as? [String: Any]
        let usage = TokenUsage(
            inputTokens: usageJSON?["input_tokens"] as? Int ?? 0,
            outputTokens: usageJSON?["output_tokens"] as? Int ?? 0
        )
        return (text, usage)
    }

    private static func parseAnnotationArray(_ text: String) -> [PassageAnnotation] {
        guard let jsonString = extractJSONArray(from: text),
              let data = jsonString.data(using: .utf8),
              let raw = try? JSONDecoder().decode([PassageAnnotation].self, from: data) else { return [] }
        return raw.filter { AnnotationCategory(rawValue: $0.type) != nil && !$0.anchor.isEmpty }
    }

    private static func parseCritique(_ text: String) -> (misses: [PassageAnnotation], cuts: [String]) {
        struct Critique: Codable { var misses: [PassageAnnotation]; var cuts: [String] }
        guard let jsonString = extractJSONObjectString(from: text),
              let data = jsonString.data(using: .utf8),
              let critique = try? JSONDecoder().decode(Critique.self, from: data) else { return ([], []) }
        let validMisses = critique.misses.filter { AnnotationCategory(rawValue: $0.type) != nil && !$0.anchor.isEmpty }
        return (validMisses, critique.cuts)
    }

    private static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") else { return nil }
        return String(text[start...end])
    }

    private static func extractJSONObjectString(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start...end])
    }

    // MARK: - Legacy grounding merge

    // Legacy's per-candidate planner (Tokenizer.extractCandidates +
    // Wikipedia.planAnnotation/lookup) does real Wikipedia search and
    // scoring that the LLM passage pass has no access to, and its prompt has
    // been tuned with specific gloss examples ("Lord of the White
    // Elephants", "Red Men of America") that the fresh 5-type taxonomy
    // prompt doesn't know about. Verification against the golden paragraph
    // gold set found premium mode missing exactly these two: a real
    // regression against legacy, not just a gap. Run legacy's resolver over
    // the same paragraph and merge in anything it confidently resolves:
    // enrich an overlapping annotation with a real Wikipedia link, or add a
    // new one for a span the LLM pass missed outright.
    private static func mergeLegacyGrounding(
        _ annotations: [PassageAnnotation],
        passage: String,
        bookContext: String,
        literaryNote: String?
    ) async -> (merged: [PassageAnnotation], added: Int, enriched: Int) {
        let tokens = Tokenizer.tokenize(passage)
        let candidates = Tokenizer.extractCandidates(from: tokens, commonWords: CommonWordsLoader.set)
            .filter { $0.kind == .reference }

        var merged = annotations
        var added = 0
        var enriched = 0
        var seenPhrases = Set<String>()

        for candidate in candidates {
            guard seenPhrases.insert(candidate.phrase.lowercased()).inserted else { continue }
            guard let grounded = await legacyGroundedAnnotation(
                for: candidate, bookContext: bookContext, literaryNote: literaryNote
            ) else { continue }

            if let idx = merged.firstIndex(where: { anchorOverlaps($0.anchor, candidate.phrase) }) {
                if merged[idx].wikipediaTitle == nil {
                    merged[idx].wikipediaTitle = grounded.wikipediaTitle
                    merged[idx].wikipediaURL = grounded.wikipediaURL
                    enriched += 1
                }
            } else if passage.contains(candidate.phrase) {
                merged.append(grounded)
                added += 1
            }
        }

        return (merged, added, enriched)
    }

    private static func legacyGroundedAnnotation(
        for candidate: AnnotationCandidate,
        bookContext: String,
        literaryNote: String?
    ) async -> PassageAnnotation? {
        let ctxBefore = candidate.contextBefore.isEmpty ? nil : candidate.contextBefore
        let ctxAfter = candidate.contextAfter.isEmpty ? nil : candidate.contextAfter

        guard let plan = await Wikipedia.planAnnotation(
            candidate.phrase,
            contextBefore: ctxBefore,
            contextAfter: ctxAfter,
            bookContext: bookContext,
            literaryNote: literaryNote
        ), plan.confidence >= 0.90 else { return nil }

        switch plan.annotationType {
        case "gloss":
            guard let gloss = plan.gloss, !gloss.isEmpty else { return nil }
            return PassageAnnotation(
                anchor: candidate.phrase,
                type: AnnotationCategory.context.rawValue,
                note: gloss,
                wikipediaTitle: nil,
                wikipediaURL: plan.wikipediaTitle.flatMap(wikipediaURL(forTitle:))
            )
        case "wikipedia":
            let result = await Wikipedia.lookup(
                candidate.phrase,
                contextBefore: ctxBefore,
                contextAfter: ctxAfter,
                bookContext: bookContext,
                preApprovedTitle: plan.wikipediaTitle,
                planSaysWikipedia: true
            )
            guard result.status == .ok, let title = result.title else { return nil }
            return PassageAnnotation(
                anchor: candidate.phrase,
                type: AnnotationCategory.context.rawValue,
                note: "Wikipedia: \(title)",
                wikipediaTitle: title,
                wikipediaURL: wikipediaURL(forTitle: title)
            )
        default:
            return nil
        }
    }

    // GutenbergTest's Wikipedia.swift doesn't expose a title-to-URL helper
    // (only the app's copy does); it's a one-liner, not worth cross-target
    // plumbing.
    private static func wikipediaURL(forTitle title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let slug = trimmed.replacingOccurrences(of: " ", with: "_")
        guard let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return "https://en.wikipedia.org/wiki/\(encoded)"
    }

    private static func anchorOverlaps(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a == b || a.contains(b) || b.contains(a)
    }

    // MARK: - Chapter-level run (Phase 5 dump for eval/run.sh-style diffing)

    // Skips very short fragments (chapter headings, single-line breaks) that
    // aren't worth a full annotation call.
    private static let minParagraphWords = 15

    static func runChapter(bookId: Int, chapterTitle: String, paragraphs rawParagraphs: [String], chapterText: String, literaryNote: String?) async -> PremiumRunRecord {
        let paragraphs = rawParagraphs.filter { $0.split(separator: " ").count >= minParagraphWords }

        var records: [PremiumRunRecord.ParagraphRecord] = []
        var totalUsage = TokenUsage()
        let start = Date()

        for (i, para) in paragraphs.enumerated() {
            let result = await annotate(passage: para, chapterText: chapterText, bookContext: chapterTitle, literaryNote: literaryNote)
            totalUsage = totalUsage + result.usage

            let (grounded, legacyAdded, legacyEnriched) = await mergeLegacyGrounding(
                result.annotations, passage: para, bookContext: chapterTitle, literaryNote: literaryNote
            )

            let msg = "  [\(i + 1)/\(paragraphs.count)] \(grounded.count) annotations"
                + " (+\(result.addedByCritique.count)/-\(result.cutByCritique.count) from critique,"
                + " +\(legacyAdded) new/\(legacyEnriched) enriched from legacy)\n"
            FileHandle.standardError.write(msg.data(using: .utf8)!)
            records.append(.init(
                passage: para,
                annotations: grounded,
                addedByCritique: result.addedByCritique,
                cutByCritique: result.cutByCritique,
                legacyAdded: legacyAdded,
                legacyEnriched: legacyEnriched
            ))
        }

        return PremiumRunRecord(
            bookId: bookId,
            chapterTitle: chapterTitle,
            model: model,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            paragraphs: records,
            totalInputTokens: totalUsage.inputTokens,
            totalOutputTokens: totalUsage.outputTokens,
            estimatedCostUSD: totalUsage.estimatedCostUSD,
            latencySeconds: Date().timeIntervalSince(start)
        )
    }
}

struct PremiumRunRecord: Codable {
    var bookId: Int
    var chapterTitle: String
    var model: String
    var generatedAt: String
    var paragraphs: [ParagraphRecord]
    var totalInputTokens: Int
    var totalOutputTokens: Int
    var estimatedCostUSD: Double
    var latencySeconds: Double

    struct ParagraphRecord: Codable {
        var passage: String
        var annotations: [PassageAnnotation]
        var addedByCritique: [PassageAnnotation]
        var cutByCritique: [PassageAnnotation]
        var legacyAdded: Int
        var legacyEnriched: Int
    }
}
