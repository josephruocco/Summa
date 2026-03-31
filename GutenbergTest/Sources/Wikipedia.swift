import Foundation

enum WikiStatus: String, Codable, Sendable {
    case ok
    case notFound
    case disambiguation
    case error
    case suppressed
}

struct WikiResult: Codable, Sendable, Hashable {
    var status: WikiStatus
    var requested: String
    var title: String?
    var extract: String?
    var pageURL: String?
    var thumbnailURL: String?
    var debug: String?
    var score: Double?
}

enum Wikipedia {
    // In-memory negative cache: terms confirmed to have no Wikipedia article are skipped
    // on subsequent page scans without re-querying. Keyed on normalized term.
    private nonisolated(unsafe) static var notFoundCache: Set<String> = []
    private nonisolated(unsafe) static var envCache: [String: String]? = nil

    static func summary(_ term: String) async -> String {
        let result = await lookup(term)
        switch result.status {
        case .ok, .disambiguation, .error, .suppressed:
            return result.extract ?? "No summary text found."
        case .notFound:
            return "No Wikipedia page found."
        }
    }

    static func lookup(
        _ term: String,
        contextBefore: String? = nil,
        contextAfter: String? = nil,
        bookContext: String? = nil
    ) async -> WikiResult {
        let requested = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return WikiResult(status: .error, requested: term, title: nil, extract: "No term.", pageURL: nil, thumbnailURL: nil, debug: nil, score: nil)
        }

        guard looksQueryable(requested) else {
            return WikiResult(
                status: .notFound,
                requested: requested,
                title: nil,
                extract: "No Wikipedia page found.",
                pageURL: nil,
                thumbnailURL: nil,
                debug: "query failed OCR quality check",
                score: nil
            )
        }

        // Skip terms already confirmed to have no Wikipedia article
        let cacheKey = normalize(requested)
        if notFoundCache.contains(cacheKey) {
            return WikiResult(status: .notFound, requested: requested, title: nil, extract: "No Wikipedia page found.", pageURL: nil, thumbnailURL: nil, debug: "negative cache hit", score: nil)
        }

        var hitDisambiguation = false
        var allBaseNotFound = true
        var bestDirectScore: Double = 0.0
        var bestSuppressedResult: WikiResult? = nil
        var hitSuspiciousDirect = false

        for query in retryQueries(for: requested) {
            if let direct = await fetchSummary(title: query) {
                if direct.status != .notFound { allBaseNotFound = false }

                let directScore = direct.status == .ok ? scoreCandidate(
                    requested: requested,
                    title: direct.title,
                    snippet: nil,
                    extract: direct.extract,
                    contextBefore: contextBefore,
                    contextAfter: contextAfter,
                    status: direct.status
                ) : 0.0
                let suspiciousDirect = direct.status == .ok && shouldCompareAgainstSearch(
                    requested: requested,
                    title: direct.title,
                    extract: direct.extract,
                    contextBefore: contextBefore,
                    contextAfter: contextAfter
                )
                if suspiciousDirect {
                    hitSuspiciousDirect = true
                    let isSingleProperNoun = requested.first?.isUppercase == true && !requested.contains(" ")
                    let searchTerm = isSingleProperNoun
                        ? requested
                        : (contextAugmentedQuery(requested, contextBefore: contextBefore, contextAfter: contextAfter) ?? requested)
                    // resolveViaSearch now tries Brave first, Wikipedia search second
                    if let resolved = await resolveViaSearch(searchTerm, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter),
                       let resolvedScore = resolved.score,
                       resolved.status == .ok,
                       resolvedScore >= max(0.62, directScore + 0.05) {
                        // Return immediately only for high-confidence results.
                        // Uncertain results fall through to the AI cross-check.
                        if resolvedScore >= 0.90 {
                            return resolved
                        }
                        if resolvedScore > (bestSuppressedResult?.score ?? 0) {
                            bestDirectScore = max(bestDirectScore, resolvedScore)
                            bestSuppressedResult = resolved
                        }
                    }
                }

                if !suspiciousDirect,
                   let accepted = verify(result: direct, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                    // Very high confidence → return immediately; uncertain → fall through to AI
                    if let s = accepted.score, s >= 0.90 {
                        return accepted
                    }
                    if (accepted.score ?? 0) > (bestSuppressedResult?.score ?? 0) {
                        bestDirectScore = max(bestDirectScore, accepted.score ?? 0)
                        bestSuppressedResult = accepted
                    }
                }

                if direct.status == .disambiguation {
                    hitDisambiguation = true
                    let searchTerm = contextAugmentedQuery(query, contextBefore: contextBefore, contextAfter: contextAfter) ?? query
                    let resolved = await resolveViaSearch(searchTerm, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter)
                    if let resolved, let accepted = verify(result: resolved, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                        // High-confidence disambiguation result: return immediately.
                        // Uncertain result: store as candidate and fall through to AI.
                        if let s = accepted.score, s >= 0.90 {
                            return accepted
                        }
                        bestDirectScore = max(bestDirectScore, accepted.score ?? 0)
                        bestSuppressedResult = accepted
                    }
                    // Don't suppress here — fall through so the outer handler can retry
                    // with a plain search, which is more reliable for single proper nouns
                    // whose literary context words mislead the disambiguation search.
                } else if direct.status == .notFound {
                    // 404: not a Wikipedia article; skip to next query variant
                    continue
                } else if direct.status == .ok {
                    // Don't exit early — track the best low-scoring result and keep trying.
                    // Context expansion below may find a better match.
                    if directScore > bestDirectScore {
                        bestDirectScore = directScore
                        bestSuppressedResult = suppress(result: direct, reason: "direct result scored too low")
                    }
                }
            }
        }

        // If all base variants 404'd or scored poorly, try phrase expansion using context
        // neighbors. E.g. "York" → 404 → try "New York"; "Indies" → 404 → try "West Indies".
        if allBaseNotFound || bestDirectScore < 0.40 {
            for query in contextExpandedQueries(for: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                if let direct = await fetchSummary(title: query) {
                    if let accepted = verify(result: direct, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                        return accepted
                    }
                    if direct.status == .disambiguation {
                        hitDisambiguation = true
                        let searchTerm = contextAugmentedQuery(query, contextBefore: contextBefore, contextAfter: contextAfter) ?? query
                        if let resolved = await resolveViaSearch(searchTerm, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter),
                           let accepted = verify(result: resolved, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                            return accepted
                        }
                    }
                }
            }
        }

        // Multi-word phrases that 404 should still get a plain search pass.
        // "Lord of the White Elephants" has no exact page, but Wikipedia search can still
        // resolve it to the concept page "White elephant".
        // Also covers 2-word abbreviated forms like "St Olav's" → Saint Olaf.
        let looksLikeMeaningfulPhrase = requested.contains(" ")
            && requested.split(separator: " ").count >= 2
        // Also run phrase search when Wikipedia found something but scored it essentially 0
        // (e.g. "St Olav's" → Wikipedia returns "Olaf II of Norway" with no word overlap →
        // clamped score 0.0, never flagged as suspicious since containsRequest fails).
        let effectivelyNotFound = allBaseNotFound || bestDirectScore < 0.10
        var bestPhraseScore: Double = 0.0
        if effectivelyNotFound && looksLikeMeaningfulPhrase {
            for query in phraseSearchQueries(for: requested) {
                if let resolved = await resolveViaSearch(query, requested: query, contextBefore: contextBefore, contextAfter: contextAfter) {
                    if resolved.status == .ok, let s = resolved.score {
                        bestPhraseScore = max(bestPhraseScore, s)
                        // High-confidence results return immediately; uncertain ones fall through to AI
                        if s >= 0.90 {
                            var accepted = resolved
                            accepted.requested = requested
                            return accepted
                        }
                        // Store as candidate for AI comparison
                        if bestSuppressedResult == nil || s > (bestSuppressedResult?.score ?? 0) {
                            var candidate = resolved
                            candidate.requested = requested
                            bestSuppressedResult = candidate
                        }
                        continue
                    }
                    if let accepted = verify(result: resolved, requested: query, contextBefore: contextBefore, contextAfter: contextAfter) {
                        var rebound = accepted
                        rebound.requested = requested
                        if let s = rebound.score, s >= 0.90 {
                            return rebound
                        }
                        if (rebound.score ?? 0) > (bestSuppressedResult?.score ?? 0) {
                            bestDirectScore = max(bestDirectScore, rebound.score ?? 0)
                            bestSuppressedResult = rebound
                        }
                        continue
                    }
                    if resolved.status == .ok {
                        var suppressed = suppress(result: resolved, reason: "phrase search result scored too low")
                        suppressed.requested = requested
                        bestSuppressedResult = suppressed
                    }
                }
            }
        }

        // Silent-redirect recovery: Wikipedia returned a 200 OK but the title has no word
        // overlap with the requested term, meaning it silently redirected elsewhere (e.g.
        // "Christiania" → Oslo). The short REST API extract rarely contains the original
        // name, so isAliasMatch never fires from the direct lookup. A plain search for the
        // original term returns snippets that DO mention it, making alias scoring work.
        let isSingleProperNoun = requested.first?.isUppercase == true && !requested.contains(" ")
        let gotSilentRedirect = !allBaseNotFound && bestDirectScore < 0.30 && isSingleProperNoun

        // Fall back to search if disambiguation was detected, or if a silent redirect was
        // detected. A pure 404 with no redirect still skips search to avoid junk.
        if hitDisambiguation || gotSilentRedirect || hitSuspiciousDirect {
            // For single proper nouns, a plain search is usually better than a context-augmented
            // one after a disambiguation hit. Queries like "Christiania Knut Hamsun Hunger"
            // can bury the canonical alias target ("Oslo") under history/meta pages.
            let searchTerm: String
            if hitDisambiguation && isSingleProperNoun {
                searchTerm = requested
            } else if hitDisambiguation {
                searchTerm = contextAugmentedQuery(requested, contextBefore: contextBefore, contextAfter: contextAfter) ?? requested
            } else {
                searchTerm = isSingleProperNoun
                    ? requested
                    : (contextAugmentedQuery(requested, contextBefore: contextBefore, contextAfter: contextAfter) ?? requested)
            }
            if let resolved = await resolveViaSearch(searchTerm, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                // resolveViaSearch scores candidates using the search result title (e.g. "Christiania"),
                // but stores the fetched summary result whose title may be the redirect target (e.g. "Oslo").
                // Re-running verify() here would re-score against the redirect title and fail. Trust the
                // score resolveViaSearch already set.
                // High-confidence → return immediately. Uncertain → store and let AI cross-check.
                if resolved.status == .ok, let s = resolved.score {
                    if s >= 0.90 {
                        return resolved
                    }
                    if s > (bestSuppressedResult?.score ?? 0) {
                        bestDirectScore = max(bestDirectScore, s)
                        bestSuppressedResult = resolved
                    }
                } else if let accepted = verify(result: resolved, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                    if let s = accepted.score, s >= 0.90 {
                        return accepted
                    }
                    if (accepted.score ?? 0) > (bestSuppressedResult?.score ?? 0) {
                        bestDirectScore = max(bestDirectScore, accepted.score ?? 0)
                        bestSuppressedResult = accepted
                    }
                } else if resolved.status == .ok {
                    if resolved.score ?? 0 > (bestSuppressedResult?.score ?? 0) {
                        bestSuppressedResult = suppress(result: resolved, reason: "fallback search result scored too low")
                    }
                }
                // Don't propagate error results — fall through to AI / bestSuppressedResult
            }
        }

        // Cache terms that had no Wikipedia article at any variant so we don't re-query them
        if allBaseNotFound {
            notFoundCache.insert(cacheKey)
        }

        // AI fallback: when pipeline is uncertain or notFound, ask Claude what this refers to.
        // Threshold matches the direct-lookup early-return (0.90): anything below that is uncertain
        // enough to warrant a cross-check against the book's context.
        let shouldTryAI = allBaseNotFound || bestDirectScore < 0.90 || (bestPhraseScore > 0 && bestPhraseScore < 0.80)
        if shouldTryAI, let bookCtx = bookContext {
            let aiSuggested = await aiSuggestTitle(
                phrase: requested,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                bookContext: bookCtx
            )
            if let suggestedTitle = aiSuggested {
                // Try direct fetch first, then fall back to search if the exact title doesn't exist
                let aiResult: WikiResult?
                if let direct = await fetchSummary(title: suggestedTitle), direct.status == .ok {
                    aiResult = direct
                } else {
                    // AI's title may be slightly off ("Haymarket, Saint Petersburg" → search → "Sennaya Square")
                    log("  🤖 AI fetch failed for \"\(requested)\" → \"\(suggestedTitle)\", trying search")
                    if let searched = await resolveViaSearch(suggestedTitle, requested: requested,
                                                             contextBefore: contextBefore,
                                                             contextAfter: contextAfter),
                       searched.status == .ok {
                        aiResult = searched
                    } else {
                        aiResult = nil
                    }
                }
                if let aiResult {
                    return WikiResult(
                        status: .ok,
                        requested: requested,
                        title: aiResult.title,
                        extract: aiResult.extract,
                        pageURL: aiResult.pageURL,
                        thumbnailURL: aiResult.thumbnailURL,
                        debug: "ai-suggested: \(suggestedTitle)",
                        score: 0.75
                    )
                }
            } else if bestDirectScore < 0.90 {
                // AI said "none" and the pipeline result was already uncertain.
                // Suppress rather than surface a likely-wrong annotation.
                log("  🤖 AI said none for \"\(requested)\" (score \(String(format: "%.2f", bestDirectScore))) — suppressing")
                if let bs = bestSuppressedResult {
                    return suppress(result: bs, reason: "AI determined: not a reference in this context")
                }
            }
        }

        return bestSuppressedResult ?? WikiResult(
            status: .notFound,
            requested: requested,
            title: nil,
            extract: "No Wikipedia page found.",
            pageURL: nil,
            thumbnailURL: nil,
            debug: "all queries failed",
            score: nil
        )
    }

    private static func aiSuggestTitle(
        phrase: String,
        contextBefore: String?,
        contextAfter: String?,
        bookContext: String
    ) async -> String? {
        let contextSnippet = [contextBefore, contextAfter]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " … ")
        let truncatedContext = contextSnippet.count > 400
            ? String(contextSnippet.prefix(400)) + "…"
            : contextSnippet
        let targetSentence = [contextBefore?.trimmingCharacters(in: .whitespacesAndNewlines),
                              "[[\(phrase)]]",
                              contextAfter?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let truncatedSentence = targetSentence.count > 700
            ? String(targetSentence.prefix(700)) + "…"
            : targetSentence
        let bookParts = bookContext.components(separatedBy: " — ")
        let chapterLabel = bookParts.first ?? bookContext
        let authorLabel = bookParts.count > 1 ? bookParts.last! : "Unknown"

        let prompt = """
        You are annotating a literary text with Wikipedia references.

        Book / chapter: \(chapterLabel)
        Author: \(authorLabel)
        Target phrase: "\(phrase)"
        Target sentence: "\(truncatedSentence)"
        Nearby context: "…\(truncatedContext)…"

        Task: identify the single best Wikipedia article for THIS SPECIFIC PHRASE as used in THIS PASSAGE.
        Rules:
        - Resolve the phrase itself as used in context.
        - If the phrase is a descriptive title, epithet, honorific, poetic expression, or culture-bound wording, you should still link it when it clearly points to a specific underlying real-world referent with a stable Wikipedia article.
        - In such cases, prefer the underlying referent over "none".
        - Prefer the most specific concrete referent clearly intended by the sentence.
        - Do not jump to a modern film, restaurant, company, song, or product unless the sentence clearly supports that sense.
        - When multiple plausible referents exist, choose "none" unless one is clearly intended by the sentence.
        - Prefer historical or literary referents supported by the passage over modern commercial or pop-culture entities.
        - If the phrase does not clearly point to a specific stable referent, reply "none".
        Examples:
          "Venetians" in an art context → "Venetian painting"
          "Romish" → "Catholic Church"
          "Great Jove" → "Jupiter (god)"
          "Carl Johann Street" → "Karl Johans gate"
          "Crates" in a philosophy context → "Crates of Thebes"
          "Kingstown" in an Irish/Dublin context → "Dún Laoghaire"
          "Thalatta" in a literary/classical context → "Anabasis (Xenophon)"
          "Lord of the White Elephants" in a Southeast Asian royal context → "White elephant (animal)"
        Reply with ONLY the exact Wikipedia article title.
        Reply "none" if:
        - It is a common word or expression
        - It is a pronoun, adverb, or generic descriptor
        - It is a minor fictional character with no dedicated Wikipedia article
        - It is a chapter heading or thematic phrase
        - It only loosely suggests a concept and does not clearly identify a specific referent
        - You are not confident there is a specific Wikipedia article for the referent intended in context
        NOTE:
        - Major fictional characters do have Wikipedia articles and should be annotated.
        - For religious titles like "Holy One" or "Heavenly Father", reply with the primary Wikipedia article for the deity as understood in context.
        - For descriptive epithets, titles, or figurative labels, return the article for the underlying referent when that referent is plainly identifiable from the passage and is the thing actually being invoked.
        Do NOT reply with an explanation or sentence — only the article title or "none".
        """

        let debugPhrases = Set(
            (envValue("SUMMA_DEBUG_AI_PROMPTS") ?? "")
                .split(separator: ",")
                .map { normalize(String($0)) }
                .filter { !$0.isEmpty }
        )
        if debugPhrases.contains(normalize(phrase)) {
            log("  🤖 PROMPT FOR \"\(phrase)\":\n\(prompt)\n")
        }

        if let suggestion = await openAISuggestTitle(prompt: prompt) {
            return suggestion
        }

        return await claudeSuggestTitle(prompt: prompt)
    }

    private static func openAISuggestTitle(prompt: String) async -> String? {
        guard let apiKey = envValue("OPENAI_API_KEY"),
              !apiKey.isEmpty else { return nil }

        let model = envValue("OPENAI_MODEL") ?? "gpt-5.4-mini"
        let body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": "minimal"],
            "max_output_tokens": 60,
            "input": [[
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": prompt
                ]]
            ]]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "https://api.openai.com/v1/responses") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let text = responseText(from: json)
        return cleanedAISuggestion(text)
    }

    private static func claudeSuggestTitle(prompt: String) async -> String? {
        guard let apiKey = envValue("ANTHROPIC_API_KEY"),
              !apiKey.isEmpty else { return nil }

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 60,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String else { return nil }

        return cleanedAISuggestion(text)
    }

    private static func responseText(from json: [String: Any]) -> String? {
        if let outputText = json["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        if let output = json["output"] as? [[String: Any]] {
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        if let text = part["text"] as? String, !text.isEmpty {
                            return text
                        }
                    }
                }
            }
        }

        return nil
    }

    private static func cleanedAISuggestion(_ text: String?) -> String? {
        guard let text else { return nil }

        let suggestion = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !suggestion.isEmpty,
              suggestion.lowercased() != "none",
              suggestion.lowercased() != "\"none\"" else { return nil }

        let wordCount = suggestion.split(separator: " ").count
        let looksLikeSentence = wordCount > 10
            || suggestion.hasPrefix("I ")
            || suggestion.contains(". ")
            || suggestion.contains("refers to")
            || suggestion.contains("I need")
        guard !looksLikeSentence else { return nil }

        log("  🤖 AI suggested → \(suggestion)")
        return suggestion
    }

    private static func fetchSummary(title: String) async -> WikiResult? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let underscored = clean.replacingOccurrences(of: " ", with: "_")

        guard let encoded = underscored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ScreenGlossMVP/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            guard code == 200 else {
                return WikiResult(
                    status: code == 404 ? .notFound : .error,
                    requested: clean,
                    title: nil,
                    extract: code == 404 ? "No Wikipedia page found." : "Wikipedia lookup failed (HTTP \(code)).",
                    pageURL: nil,
                    thumbnailURL: nil,
                    debug: "summary HTTP \(code) url=\(url.absoluteString) body=\(String(data: data, encoding: .utf8) ?? "")",
                    score: nil
                )
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return WikiResult(status: .error, requested: clean, title: nil, extract: "Bad JSON.", pageURL: nil, thumbnailURL: nil, debug: "summary bad JSON", score: nil)
            }

            let pageType = (obj["type"] as? String)?.lowercased()
            let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let extract = (obj["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let contentURLs = obj["content_urls"] as? [String: Any]
            let desktop = contentURLs?["desktop"] as? [String: Any]
            let pageURL = desktop?["page"] as? String
            let thumb = obj["thumbnail"] as? [String: Any]
            let thumbURL = thumb?["source"] as? String
            let extractLower = (extract ?? "").lowercased()
            let isDisamb = (pageType == "disambiguation")
                || extractLower.contains("may refer to")
                || extractLower.contains("can refer to")

            return WikiResult(
                status: isDisamb ? .disambiguation : .ok,
                requested: clean,
                title: title,
                extract: extract ?? (isDisamb ? "This term is ambiguous." : nil),
                pageURL: pageURL,
                thumbnailURL: thumbURL,
                debug: isDisamb ? "disambiguation detected via type/extract" : nil,
                score: nil
            )
        } catch {
            return WikiResult(
                status: .error,
                requested: clean,
                title: nil,
                extract: "Wikipedia lookup failed: \(error.localizedDescription)",
                pageURL: nil,
                thumbnailURL: nil,
                debug: "summary error \(error)",
                score: nil
            )
        }
    }

    private static func resolveViaSearch(
        _ term: String,
        requested: String,
        contextBefore: String?,
        contextAfter: String?
    ) async -> WikiResult? {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        // Brave Search finds the right Wikipedia page title via a real web index —
        // much more semantically accurate than Wikipedia's own keyword search.
        // Try it first; fall through to Wikipedia search if key is absent or no hit.
        if let braveResult = await resolveViaBraveSearch(q, requested: requested,
                                                         contextBefore: contextBefore,
                                                         contextAfter: contextAfter) {
            return braveResult
        }

        guard let searchURL = makeSearchURL(query: q, limit: 6) else { return nil }

        var req = URLRequest(url: searchURL)
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ScreenGlossMVP/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else {
                return WikiResult(status: .error, requested: q, title: nil, extract: "Wikipedia search failed (HTTP \(code)).", pageURL: nil, thumbnailURL: nil, debug: "search HTTP \(code)", score: nil)
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = obj["query"] as? [String: Any],
                  let search = query["search"] as? [[String: Any]]
            else {
                return WikiResult(status: .error, requested: q, title: nil, extract: "Wikipedia search JSON parse failed.", pageURL: nil, thumbnailURL: nil, debug: "search parse fail", score: nil)
            }

            let candidates: [SearchCandidate] = search.compactMap { entry in
                guard let title = entry["title"] as? String else { return nil }
                let snippetHTML = (entry["snippet"] as? String) ?? ""
                let snippet = snippetHTML
                    .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return SearchCandidate(title: title, snippet: snippet)
            }
            guard !candidates.isEmpty else {
                return WikiResult(status: .notFound, requested: q, title: nil, extract: "No Wikipedia page found.", pageURL: nil, thumbnailURL: nil, debug: "search empty", score: nil)
            }

            let ranked = rankCandidates(
                requested: requested,
                candidates: candidates,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )
            // Single proper nouns and title-cased phrases often need deeper verification because
            // the canonical target can rank below surface-form lookalikes in the raw search list
            // (e.g. "Christiania" -> "Oslo"). Fetch more summaries before we suppress.
            let candidateLimit = requested.contains(where: { $0.isUppercase }) ? 8 : 3
            let topCandidates = Array(ranked.prefix(candidateLimit))
            var resolved: [(WikiResult, Double)] = []

            for candidate in topCandidates {
                guard let summary = await fetchSummary(title: candidate.title) else { continue }
                let score = scoreCandidate(
                    requested: requested,
                    title: candidate.title,
                    snippet: candidate.snippet,
                    extract: summary.extract,
                    contextBefore: contextBefore,
                    contextAfter: contextAfter,
                    status: summary.status
                )
                var enriched = summary
                enriched.requested = requested
                enriched.score = score
                resolved.append((enriched, score))
            }

            guard !resolved.isEmpty else {
                return WikiResult(status: .error, requested: q, title: nil, extract: "Failed to resolve Wikipedia page.", pageURL: nil, thumbnailURL: nil, debug: "search resolved no summary", score: nil)
            }

            // Sort by score descending; use original Wikipedia search rank as tiebreaker
            // so that when multiple candidates score equally (e.g. two alias-match results),
            // the one Wikipedia ranked more relevant wins.
            let indexedResolved = resolved.enumerated().map { ($0.offset, $0.element) }
            let sorted = indexedResolved.sorted { lhs, rhs in
                if abs(lhs.1.1 - rhs.1.1) < 0.01 { return lhs.0 < rhs.0 }
                return lhs.1.1 > rhs.1.1
            }.map { $0.1 }
            let best = sorted[0].0
            let margin = sorted.count > 1 ? sorted[0].1 - sorted[1].1 : sorted[0].1

            if best.status == .disambiguation {
                return suppress(result: best, reason: "top candidate remained disambiguation")
            }

            let bestReqWords = requested.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            let bestAllCommon = bestReqWords.count >= 2
                && bestReqWords.allSatisfy { CommonWordsLoader.set.contains($0) }
            let searchThreshold: Double = bestAllCommon ? 0.80 : 0.58
            guard (best.score ?? 0) >= searchThreshold else {
                return suppress(result: best, reason: "best search candidate below threshold")
            }

            // Skip margin check for two cases where a close runner-up is expected:
            //
            // 1. Genuine alias matches — the requested term doesn't appear in the returned title
            //    but was found verbatim in the article body (e.g. "Pegu" → "Hanthawaddy kingdom").
            //    Multiple alias-matching articles can score within 0.08 of each other; enforcing
            //    a margin just suppresses valid tied results.
            //
            // 2. Super-title matches — the title fully contains the request as a subsequence of
            //    words (e.g. "Raskolnikov" → "Rodion Raskolnikov"). The runner-up is often another
            //    article about the same subject (e.g. "Crime and Punishment") so a narrow margin
            //    is expected and should not suppress the correct top result.
            //
            // Title-prefix wins (e.g. "Christiania SK" for "Christiania") still respect the
            // margin constraint since those require disambiguation between similarly named articles.
            let bestNormTitle = normalize(best.title ?? "")
            let reqNorm = normalize(requested)
            let looksLikeAlias = !bestNormTitle.contains(reqNorm) && !reqNorm.contains(bestNormTitle)
            // Only bypass margin for single-word super-title matches (e.g. "Raskolnikov" →
            // "Rodion Raskolnikov"). Multi-word phrases like "University Street" appear verbatim
            // in unrelated directory articles and should still require a margin.
            let titleContainsRequest = !reqNorm.isEmpty && !reqNorm.contains(" ") && bestNormTitle.contains(reqNorm)
            let highConfidence = (looksLikeAlias || titleContainsRequest) && (best.score ?? 0) >= 0.69
            guard margin >= 0.08 || highConfidence else {
                return suppress(result: best, reason: "search candidates too close")
            }

            return best
        } catch {
            return WikiResult(status: .error, requested: q, title: nil, extract: "Wikipedia search failed: \(error.localizedDescription)", pageURL: nil, thumbnailURL: nil, debug: "search error \(error)", score: nil)
        }
    }

    // MARK: - Brave Web Search fallback

    /// Calls the Brave Search API scoped to en.wikipedia.org, extracts Wikipedia article
    /// titles from the result URLs, and scores each via the existing `scoreCandidate` pipeline.
    /// Returns nil when BRAVE_SEARCH_API_KEY is not set or no candidate clears the threshold.
    private static func resolveViaBraveSearch(
        _ term: String,
        requested: String,
        contextBefore: String?,
        contextAfter: String?
    ) async -> WikiResult? {
        guard let apiKey = envValue("BRAVE_SEARCH_API_KEY"),
              !apiKey.isEmpty else { return nil }

        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        // Replace historical city names with modern equivalents so Brave's index
        // can resolve them correctly. "University Street Christiania" → "University Street Oslo"
        let historicalCityAliases: [String: String] = [
            "Christiania": "Oslo", "Kristiania": "Oslo",
            "Constantinople": "Istanbul", "Leningrad": "Saint Petersburg",
            "Bombay": "Mumbai", "Calcutta": "Kolkata", "Peking": "Beijing",
            "Saigon": "Ho Chi Minh City", "Rangoon": "Yangon",
        ]
        var normalizedQ = q
        for (historical, modern) in historicalCityAliases {
            normalizedQ = normalizedQ.replacingOccurrences(of: historical, with: modern)
        }

        // For honorific phrases like "St Olav's", the abbreviated/possessive form may
        // confuse Brave's index.  Also try the expanded form ("Saint Olav") as a fallback.
        let reqNormForExpansion = normalize(stripPossessive(requested.trimmingCharacters(in: .whitespacesAndNewlines)))
        var braveQueries: [String] = [normalizedQ]
        for expanded in honorificExpansions(reqNormForExpansion) where expanded != reqNormForExpansion {
            let titleCased = expanded.split(separator: " ").map { w in
                String(w.prefix(1)).uppercased() + String(w.dropFirst())
            }.joined(separator: " ")
            if !braveQueries.contains(titleCased) { braveQueries.append(titleCased) }
        }

        // Try each query in order; stop once we have gate-passing Wikipedia candidates.
        var candidates: [SearchCandidate] = []
        for bq in braveQueries {
            var comps = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
            comps.queryItems = [
                URLQueryItem(name: "q",     value: "\(bq) site:en.wikipedia.org"),
                URLQueryItem(name: "count", value: "8"),
            ]
            guard let url = comps.url else { continue }
            var urlReq = URLRequest(url: url)
            urlReq.timeoutInterval = 8
            urlReq.setValue(apiKey,             forHTTPHeaderField: "X-Subscription-Token")
            urlReq.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: urlReq),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let web = obj["web"] as? [String: Any],
                  let results = web["results"] as? [[String: Any]] else { continue }

            // Extract Wikipedia article titles from result URLs
            var extracted: [SearchCandidate] = []
            for entry in results {
                guard let urlStr = entry["url"] as? String,
                      urlStr.hasPrefix("https://en.wikipedia.org/wiki/") else { continue }
                let rawSlug = urlStr.replacingOccurrences(of: "https://en.wikipedia.org/wiki/", with: "")
                let title   = rawSlug
                    .removingPercentEncoding?
                    .replacingOccurrences(of: "_", with: " ")
                    ?? (entry["title"] as? String ?? "")
                let snippet = (entry["description"] as? String) ?? ""
                extracted.append(SearchCandidate(title: title, snippet: snippet))
            }

            let ranked = rankCandidates(requested: requested, candidates: extracted,
                                        contextBefore: contextBefore, contextAfter: contextAfter)
            if !ranked.isEmpty {
                candidates = extracted  // use full unfiltered list; re-rank below
                break
            }
            // No gate-passing candidates for this query — try next
        }
        guard !candidates.isEmpty else { return nil }

        // Re-rank with the same scoring used for Wikipedia search candidates
        let ranked = rankCandidates(
            requested: requested,
            candidates: candidates,
            contextBefore: contextBefore,
            contextAfter: contextAfter
        )
        let topCandidates = Array(ranked.prefix(3))
        // Carry the Brave snippet alongside each result so we can use it as
        // explicit-match evidence below (the snippet is Brave's own relevance signal).
        var resolvedCandidates: [(WikiResult, Double, String)] = []

        for candidate in topCandidates {
            guard let summary = await fetchSummary(title: candidate.title) else { continue }
            let score = scoreCandidate(
                requested: requested,
                title: candidate.title,
                snippet: candidate.snippet,
                extract: summary.extract,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                status: summary.status
            )
            var enriched = summary
            enriched.requested = requested
            enriched.score = score
            resolvedCandidates.append((enriched, score, candidate.snippet))
        }
        guard !resolvedCandidates.isEmpty else { return nil }

        var sorted = resolvedCandidates.sorted { $0.1 > $1.1 }

        // When the request looks like a saint/honorific name ("St X", "Saint X"),
        // demote institution titles that are merely named after the saint rather than
        // being the article about the saint/person.  E.g. "St Olav's" should prefer
        // "Olaf II of Norway" over "St. Olav's University Hospital".
        let reqNormForInst = normalize(stripPossessive(requested.trimmingCharacters(in: .whitespacesAndNewlines)))
        let looksLikeSaintQuery = reqNormForInst.hasPrefix("saint ") || reqNormForInst.hasPrefix("st ")
        if looksLikeSaintQuery {
            let institutionWords = ["hospital", "university", "church", "school",
                                    "college", "cathedral", "foundation", "clinic",
                                    "station", "airport", "bridge", "street", "avenue"]
            sorted = sorted.sorted { lhs, rhs in
                let lTitle = lhs.0.title?.lowercased() ?? ""
                let rTitle = rhs.0.title?.lowercased() ?? ""
                let lIsInst = institutionWords.contains { lTitle.contains($0) }
                let rIsInst = institutionWords.contains { rTitle.contains($0) }
                if lIsInst != rIsInst { return !lIsInst } // non-institutions first
                return lhs.1 > rhs.1
            }
        }

        var best      = sorted[0].0
        var bestScore = sorted[0].1
        let bestSnippet = sorted[0].2

        // Brave's own snippet is direct relevance evidence: if the snippet contains
        // any significant content word from the request (singularized, honorific-expanded),
        // trust Brave's ranking and floor the score to 0.60.
        // Word-level matching handles transliteration variants like "St Olav's" → Saint Olaf
        // where the snippet says "also known as Olav" (not "Olavs").
        let reqNorm   = reqNormForInst  // already computed above
        let reqExp    = honorificExpansions(reqNorm).last ?? reqNorm
        let normSnippet = normalize(bestSnippet)
        // Strip honorific abbreviations so "st" alone doesn't match unrelated snippets.
        let honorificPrefixes: Set<String> = ["st", "dr", "mt", "ft", "mr", "mrs", "ms"]
        let reqContentWords = Set(reqNorm.split(separator: " ").map { singularize(String($0)) })
            .subtracting(honorificPrefixes)
        let reqExpContentWords = Set(reqExp.split(separator: " ").map { singularize(String($0)) })
            .subtracting(honorificPrefixes)
        let snippetWords = Set(normSnippet.split(separator: " ").map { singularize(String($0)) })
        // For multi-word requests (≥2 content words) require at least 2 snippet words to match,
        // so a single shared word like "jove" in "Xenodon pulcher" or "pulcher" in a species
        // article doesn't floor an otherwise low-scoring result to 0.60.
        // Single-word requests only need 1 match (the word itself) — already handled by alias scoring.
        let snippetMatchCount = reqContentWords.intersection(snippetWords).count
            + reqExpContentWords.subtracting(reqContentWords).intersection(snippetWords).count
        let reqContentWordCount = max(reqContentWords.count, reqExpContentWords.count)
        let hasSnippetEvidence = reqContentWordCount <= 1
            ? snippetMatchCount >= 1
            : snippetMatchCount >= 2
        if hasSnippetEvidence, bestScore < 0.60, best.status == .ok {
            bestScore = 0.60
            best.score = bestScore
        }

        guard bestScore >= 0.50, best.status == .ok else { return nil }
        return best
    }

    private static func makeSearchURL(query: String, limit: Int) -> URL? {
        var comps = URLComponents(string: "https://en.wikipedia.org/w/api.php")
        comps?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "utf8", value: "1")
        ]
        return comps?.url
    }

    private struct SearchCandidate {
        let title: String
        let snippet: String
    }

    private static func rankCandidates(
        requested: String,
        candidates: [SearchCandidate],
        contextBefore: String?,
        contextAfter: String?
    ) -> [SearchCandidate] {
        candidates
            .filter { passesLexicalGate(requested: requested, candidateTitle: $0.title, snippet: $0.snippet) }
            .sorted {
            scoreCandidate(
                requested: requested,
                title: $0.title,
                snippet: $0.snippet,
                extract: nil,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                status: .ok
            ) > scoreCandidate(
                requested: requested,
                title: $1.title,
                snippet: $1.snippet,
                extract: nil,
                contextBefore: contextBefore,
                contextAfter: contextAfter,
                status: .ok
            )
        }
    }

    private static func verify(
        result: WikiResult,
        requested: String,
        contextBefore: String?,
        contextAfter: String?
    ) -> WikiResult? {
        guard result.status == .ok else { return nil }

        let score = scoreCandidate(
            requested: requested,
            title: result.title,
            snippet: nil,
            extract: result.extract,
            contextBefore: contextBefore,
            contextAfter: contextAfter,
            status: result.status
        )

        // Phrases made entirely of common English words (e.g. "Castle Hill", "Southern Seas")
        // need a much higher confidence bar — a Wikipedia hit is likely coincidental.
        let reqPhraseWords = requested.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let allWordsCommon = reqPhraseWords.count >= 2
            && reqPhraseWords.allSatisfy { CommonWordsLoader.set.contains($0) }
        let directThreshold: Double = allWordsCommon ? 0.80 : 0.62
        guard score >= directThreshold else { return nil }

        var accepted = result
        accepted.score = score
        return accepted
    }

    private static func suppress(result: WikiResult, reason: String) -> WikiResult {
        var suppressed = result
        suppressed.status = .suppressed
        suppressed.debug = [result.debug, reason].compactMap { $0 }.joined(separator: " | ")
        return suppressed
    }

    private static func retryQueries(for requested: String) -> [String] {
        let normalized = requested
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        let repaired = repairHyphenation(normalized)
        let strippedPossessive = stripPossessive(repaired)
        let singular = singularize(strippedPossessive)

        // Strip trailing generic street-type suffixes so that e.g. "Carl Johann Street"
        // also queries "Carl Johann", which can then match "Karl Johans gate" via search.
        let streetSuffixes: Set<String> = ["street", "road", "avenue", "lane", "boulevard", "drive"]
        let streetStripped: String? = {
            let words = repaired.split(separator: " ").map(String.init)
            guard words.count >= 2,
                  let last = words.last,
                  streetSuffixes.contains(last.lowercased()) else { return nil }
            return words.dropLast().joined(separator: " ")
        }()

        var seen = Set<String>()
        return ([requested, normalized, repaired, strippedPossessive, singular]
            + [streetStripped].compactMap { $0 })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(normalize($0)).inserted }
    }

    // Generates phrase candidates by combining the term with capitalized neighbors from
    // context, for use when base single-word variants all 404 or score poorly.
    // E.g. term="York", contextBefore="…in New…" → ["New York"]
    //      term="Wales", contextBefore="…New South…" → ["South Wales", "New South Wales"]
    private static func contextExpandedQueries(
        for term: String,
        contextBefore: String?,
        contextAfter: String?
    ) -> [String] {
        // Only expand single capitalized words — phrases already have their neighbors baked in
        guard !term.contains(" "), term.first?.isUppercase == true else { return [] }

        let beforeWords = (contextBefore ?? "")
            .split(separator: " ").map(String.init)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.count > 1 }

        let afterWords = (contextAfter ?? "")
            .split(separator: " ").map(String.init)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && $0.count > 1 }

        var seen = Set<String>()
        var candidates: [String] = []

        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { return }
            candidates.append(t)
        }

        // One word before + term (e.g. "New York", "West Indies")
        if let prev = beforeWords.last, prev.first?.isUppercase == true {
            add("\(prev) \(term)")
        }

        // Term + one word after (e.g. "Cape Town")
        if let next = afterWords.first, next.first?.isUppercase == true {
            add("\(term) \(next)")
        }

        // Two words before + term (e.g. "New South Wales")
        if beforeWords.count >= 2 {
            let p2 = beforeWords[beforeWords.count - 2]
            let p1 = beforeWords[beforeWords.count - 1]
            if p2.first?.isUppercase == true, p1.first?.isUppercase == true {
                add("\(p2) \(p1) \(term)")
            }
        }

        return candidates
    }

    private static func phraseSearchQueries(for requested: String) -> [String] {
        let phraseConnectors: Set<String> = ["of", "the", "and", "de", "la", "da", "van", "von"]
        let cleaned = requested
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
        let words = cleaned
            .split(separator: " ")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }

        guard words.count >= 3 else { return [cleaned] }

        var seen = Set<String>()
        var queries: [String] = []

        func add(_ s: String) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(normalize(trimmed)).inserted else { return }
            queries.append(trimmed)
        }

        add(cleaned)
        add(singularize(cleaned))

        let tail2 = words.suffix(2).joined(separator: " ")
        add(tail2)
        add(singularize(tail2))

        let meaningful = words.filter { !phraseConnectors.contains($0.lowercased()) }
        if meaningful.count >= 2 {
            let meaningfulTail = meaningful.suffix(2).joined(separator: " ")
            add(meaningfulTail)
            add(singularize(meaningfulTail))
        }

        return queries
    }

    private static func scoreCandidate(
        requested: String,
        title: String?,
        snippet: String?,
        extract: String?,
        contextBefore: String?,
        contextAfter: String?,
        status: WikiStatus
    ) -> Double {
        // Strip possessive markers before normalizing so they don't produce noise tokens.
        // Handles both trailing possessives ("Coleridge's" → "Coleridge") and mid-phrase
        // possessives ("Virginia's Blue Ridge" → "Virginia Blue Ridge").
        let reqStripped = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "'s ", with: " ")   // mid-phrase: "Virginia's Blue"
            .replacingOccurrences(of: "\u{2019}s ", with: " ")
            .replacingOccurrences(of: "'s", with: "")     // trailing: "Coleridge's"
            .replacingOccurrences(of: "\u{2019}s", with: "")
        let req = normalize(reqStripped)
        // Expanded form for honorific abbreviations ("st olav" → "saint olav")
        // Only expands leading "st/dr/mt/ft" in multi-word phrases to avoid confusing "Street"
        let reqExpanded = honorificExpansions(req).last ?? req
        let normalizedTitle = normalize(title ?? "")
        let context = normalize([contextBefore, contextAfter].compactMap { $0 }.joined(separator: " "))
        let summary = normalize([snippet, extract].compactMap { $0 }.joined(separator: " "))

        var score = 0.0

        // Use whichever form (original or honorific-expanded) matches the title better
        let reqForTitle = (normalizedTitle.contains(reqExpanded) || reqExpanded.contains(normalizedTitle)) ? reqExpanded : req

        if normalizedTitle == req, !req.isEmpty {
            score += 0.42
        } else if normalizedTitle.hasPrefix(reqForTitle) || normalizedTitle.contains(reqForTitle) || reqForTitle.contains(normalizedTitle) {
            score += 0.24
        } else {
            score -= 0.12
        }

        score += min(0.18, Double(commonPrefixLen(normalizedTitle, reqForTitle)) * 0.03)

        let reqWordList = req.split(separator: " ").map(String.init)
        let reqExpandedWordList = reqExpanded.split(separator: " ").map(String.init)
        let titleWordList = normalizedTitle.split(separator: " ").map(String.init)
        let reqWords = Set(reqWordList)
        let reqExpandedWords = Set(reqExpandedWordList)
        let titleWords = Set(titleWordList)
        let singularReqWords = Set(reqWordList.map(singularize))
        let singularTitleWords = Set(titleWordList.map(singularize))
        let summaryWords = Set(summary.split(separator: " ").map(String.init))
        // Use the max overlap between original and expanded forms
        let titleOverlap = max(reqWords.intersection(titleWords).count,
                               reqExpandedWords.intersection(titleWords).count)
        let singularTitleOverlap = singularReqWords.intersection(singularTitleWords).count
        let summaryOverlap = reqWords.intersection(summaryWords).count
        let requestedHasUppercase = requested.contains { $0.isUppercase }
        let loweredSummary = summary.lowercased()
        let rawContextWords = Set(context.split(separator: " ").map(String.init))
        let filteredContext = rawContextWords.subtracting(stopWords)
        let filteredSummary = summaryWords.subtracting(stopWords)
        let effectiveContext = filteredContext.isEmpty ? rawContextWords : filteredContext
        let effectiveSummary = filteredContext.isEmpty ? summaryWords : filteredSummary
        let contextSummaryOverlap = effectiveContext.intersection(effectiveSummary)

        // Alias/redirect detection: the queried term appears verbatim in the article body
        // despite no title overlap. Handles historical name redirects (e.g. "Christiania" → Oslo).
        // We check both the normalized word set AND the raw extract tokenized on non-alphanumeric
        // boundaries, so "Christiania," or "Christiania." are still matched.
        let rawBody = [(snippet ?? ""), (extract ?? "")].joined(separator: " ").lowercased()
        let rawBodyWords = Set(rawBody.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        // Alias/redirect: use the Wikipedia EXTRACT ONLY (not the Brave snippet) to avoid
        // circular confirmation — Brave snippets always contain the search term by definition.
        // Require the term to appear early (first 300 chars) OR at least twice in the extract.
        // Keeps "Christiania" → Oslo (first sentence mentions Christiania) and "Siam" → Thailand,
        // but suppresses "Romish" → "Ex officio oath" (incidental mention) and fictional names
        // like "Ylajali" → "Hunger (Hamsun novel)" (not mentioned in article intro at all).
        let extractBody = (extract ?? "").lowercased()
        let extractBodyWords = Set(extractBody.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        // Alias/redirect detection — use only the Wikipedia EXTRACT (not Brave snippet) to
        // avoid circular confirmation. Two ways to qualify:
        // 1. The term appears verbatim in the extract (e.g. "Christiania" in Oslo's article).
        // 2. The term is a spelling variant of a title word — ≥5-char common prefix covering
        //    ≥60% of the shorter word (e.g. "Alleghanies" ↔ "allegheny" share "allegh").
        //    This handles archaic/variant spellings where the extract uses the modern form.
        let isSpellingVariant = titleWordList.contains { titleWord in
            guard titleWord.count >= 4 else { return false }
            let prefLen = commonPrefixLen(req, titleWord)
            return prefLen >= 5
                && Double(prefLen) / Double(min(req.count, titleWord.count)) >= 0.60
        }
        let isAliasMatch = requestedHasUppercase
            && !req.contains(" ")
            && !req.isEmpty
            && titleOverlap == 0
            && (extractBodyWords.contains(req) || isSpellingVariant)

        // Length mismatch penalty — skipped for alias matches since title divergence is expected
        if !isAliasMatch {
            score -= min(0.12, Double(abs(normalizedTitle.count - req.count)) * 0.01)
        }

        if !reqWords.isEmpty {
            score += Double(titleOverlap) * 0.12
            score += Double(max(0, singularTitleOverlap - titleOverlap)) * 0.10
            score += Double(summaryOverlap) * 0.05
        }

        if titleOverlap == 0, !normalizedTitle.contains(req), !req.contains(normalizedTitle) {
            if isAliasMatch {
                // Strong redirect signal — term is in the article body (e.g. "Christiania" → Oslo).
                // Reduce the bonus when the article is about entertainment/pop-culture and there is
                // no context overlap: a common name like "Nellie" incidentally appears in many film
                // or TV articles as a character name, but those are never the intended lookup.
                let entertainmentMarkers: Set<String> = ["film", "movie", "series", "album", "song",
                                                          "band", "television", "discography", "soundtrack"]
                let titleHasEntertainment = !entertainmentMarkers.isDisjoint(with: titleWords)
                let aliasBonus: Double = (titleHasEntertainment && contextSummaryOverlap.isEmpty) ? 0.28 : 0.76
                score += aliasBonus
            } else {
                score -= 0.35
            }
        }

        // Prefix-title bonus: single-word proper nouns often resolve to a canonical article
        // whose title starts with the requested token plus a qualifier (e.g. "Hanoverian Army").
        // Do not give this bonus to suffix/contains matches like "Freetown Christiania".
        if requestedHasUppercase,
           reqWords.count == 1,
           let requestedWord = reqWordList.first,
           titleWordList.first == requestedWord,
           titleWords.count >= 2 {
            score += 0.24
        }

        // Clean surname match bonus: "Coleridge" → "Samuel Taylor Coleridge".
        if requestedHasUppercase,
           reqWordList.count == 1,
           let requestedWord = reqWordList.first,
           titleWordList.last == requestedWord,
           titleWordList.count >= 2 {
            score += 0.12
        }

        // Multi-word phrase subset bonus: all request words appear in the title
        // (e.g. "Dorian Gray" → "The Picture of Dorian Gray"). This is strong evidence
        // we have the right article even when the title has extra surrounding words.
        if reqWords.count >= 2, !reqWords.isEmpty, reqWords.isSubset(of: titleWords) {
            score += 0.12
        }

        // Lemma-equivalent phrase bonus: "White Elephants" should strongly match the
        // concept article "White elephant", not lose to a title that merely contains
        // the plural phrase with an unrelated leading qualifier.
        if singularReqWords.count >= 2, !singularReqWords.isEmpty {
            if singularReqWords == singularTitleWords {
                score += 0.18
            } else if singularReqWords.isSubset(of: singularTitleWords) {
                score += 0.08
            }
        }

        // Context scoring: strip stop words so common words don't inflate overlap.
        if !context.isEmpty {
            score += min(0.28, Double(effectiveContext.intersection(effectiveSummary).count) * 0.07)
            score += min(0.14, Double(effectiveContext.intersection(titleWords).count) * 0.07)
        }

        // Parenthetical disambiguation scoring: "Mercury (planet)" vs "Mercury (mythology)".
        // A matching parenthetical is strong evidence we have the right sense.
        // Entertainment parentheticals that don't match context get a heavy penalty so that
        // "the Whale" (tail of "Whiteness of the Whale") doesn't resolve to "The Whale (2022 film)".
        let entertainmentParenMarkers: Set<String> = ["film", "movie", "series", "album",
                                                       "song", "band", "television", "soundtrack"]
        if let paren = extractParenthetical(title ?? ""), !context.isEmpty {
            let parenWords = Set(normalize(paren).split(separator: " ").map(String.init)).subtracting(stopWords)
            let contextWords = Set(context.split(separator: " ").map(String.init)).subtracting(stopWords)
            let parenIsEntertainment = !entertainmentParenMarkers.isDisjoint(with: parenWords)
            if !parenWords.isEmpty && !contextWords.isEmpty {
                if !parenWords.intersection(contextWords).isEmpty {
                    score += 0.28
                } else if parenIsEntertainment {
                    // Entertainment article whose genre tag (film/album/series…) doesn't
                    // appear in the literary context — almost certainly a false positive.
                    score -= 0.45
                } else {
                    // Non-entertainment parenthetical (e.g. "Haymarket (Boston)") that doesn't
                    // match context is still strong evidence of the wrong sense — raise penalty.
                    score -= 0.25
                }
            }
        }

        // Visual-art attribution penalty: article is about a specific painting/artwork
        // (e.g. "Pallas Athena (Rembrandt)") but context shows no art discussion.
        let visualArtWords: Set<String> = ["painting", "canvas", "portrait", "artwork", "fresco", "mural"]
        if !visualArtWords.isDisjoint(with: summaryWords), contextSummaryOverlap.isEmpty {
            score -= 0.30
        }

        // Entertainment-title penalty: when the Wikipedia article title itself contains
        // entertainment words (e.g. "Songs from the Southern Seas") and context shows
        // no overlap with the article summary, it's almost certainly the wrong sense.
        let entertainmentTitleWords: Set<String> = ["song", "songs", "album", "film", "films",
                                                     "movie", "movies", "soundtrack", "discography"]
        if !entertainmentTitleWords.isDisjoint(with: titleWords), contextSummaryOverlap.isEmpty {
            score -= 0.35
        }

        // TV/media extract penalty: article extract describes a television programme, game show,
        // reality series etc. — almost never the right match for a literary reference.
        // "Thank God You're Here" (game show), "The Bachelor" etc. score falsely high on
        // title-word overlap with common English phrases.
        let tvMarkers = ["television series", "television show", "game show", "reality show",
                         "sitcom", "television programme", "television program", "tv series"]
        if tvMarkers.contains(where: { loweredSummary.contains($0) }), contextSummaryOverlap.isEmpty {
            score -= 0.55
        }

        // Biological-taxon penalty: article describes a genus/species (e.g. "Thalatta is a
        // genus of moths"). Literary references almost never point to taxonomic articles.
        // Applied unconditionally — even if a few context words overlap, a taxonomy article
        // is almost never the right match for a literary phrase.
        if loweredSummary.contains(" genus of ") || loweredSummary.contains(" species of ")
            || loweredSummary.hasPrefix("genus ") || loweredSummary.hasPrefix("species ") {
            score -= 0.55
        }

        // Meta/index pages are almost never the right destination for contextual lookups.
        if normalizedTitle.hasPrefix("list of")
            || normalizedTitle.hasPrefix("timeline of")
            || normalizedTitle.hasPrefix("history of")
            || normalizedTitle.hasPrefix("outline of")
            || normalizedTitle.hasPrefix("index of") {
            score -= 0.40
        }

        // Aggregation-page penalty: filmography/discography/bibliography/etc. articles are
        // catalogs of works, not canonical articles about a subject. An alias match here
        // ("Nellie" appears inside a filmography article) is always spurious.
        let aggregationSuffixes = ["filmography", "discography", "bibliography", "videography",
                                   "television", "performances", "chronology", "recordings"]
        if aggregationSuffixes.contains(where: { normalizedTitle.hasSuffix($0) }) {
            score -= 0.50
        }

        // Political-movement suffix penalty: titles like "Venetian nationalism", "Catalan separatism"
        // are about modern political movements — rarely the right match for literary/classical refs.
        // Only apply when the query itself contains no political keywords.
        let politicalSuffixes = ["nationalism", "separatism", "independence movement",
                                 "irredentism", "autonomy movement"]
        let reqLower = req.lowercased()
        if politicalSuffixes.contains(where: { normalizedTitle.hasSuffix($0) }),
           !reqLower.contains("nation") && !reqLower.contains("politic") &&
           !reqLower.contains("independen") && !reqLower.contains("separati") {
            score -= 0.55
        }

        // "Named-after" penalty: single-word query where the title starts with the exact
        // term but has additional words (e.g. "Christiania Spigerverk" for "Christiania").
        // These articles are named after the place/person, not the canonical article about it.
        if !req.contains(" "), !req.isEmpty,
           normalizedTitle.hasPrefix(req + " "),
           titleWords.count >= 2 {
            score -= 0.18
        }

        // Comma-geographic disambiguation penalty: Wikipedia titles like "Castle Hill, Huddersfield"
        // use "Term, Location" to disambiguate generic place names. When the requested term has no
        // comma but the article title does, the term alone is too generic — penalise unless the
        // location qualifier actually appears in the surrounding context.
        if !req.contains(","),
           let rawTitle = title,
           let commaIdx = rawTitle.firstIndex(of: ",") {
            let qualifier = String(rawTitle[rawTitle.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
            let qualifierWords = Set(normalize(qualifier).split(separator: " ").map(String.init)).subtracting(stopWords)
            let contextAllWords = Set(context.split(separator: " ").map(String.init))
            if !qualifierWords.isEmpty && qualifierWords.isDisjoint(with: contextAllWords) {
                score -= 0.35
            }
        }

        if loweredSummary.contains("may refer to") || loweredSummary.contains("can refer to") {
            score -= 0.45
        }

        if status == .disambiguation {
            score -= 0.45
        }

        if !requestedHasUppercase && (titleWords.count >= 2 || loweredSummary.contains("born")) {
            score -= 0.18
        }

        let sportsWords: Set<String> = ["baseball", "basketball", "football", "club", "team", "league", "season", "player"]
        let biographyWords: Set<String> = ["actor", "actress", "politician", "rapper", "singer", "footballer", "cricketer", "minister", "coach", "player", "born"]
        let literaryRoleWords: Set<String> = ["poet", "writer", "author", "novelist", "philosopher", "critic", "theologian", "historian"]

        if requestedHasUppercase,
           reqWords.count == 1,
           let requestedWord = reqWordList.first,
           titleWordList.last == requestedWord,
           titleWordList.count >= 2,
           !literaryRoleWords.isDisjoint(with: summaryWords) {
            score += 0.20
        }

        if !sportsWords.isDisjoint(with: summaryWords), contextSummaryOverlap.isEmpty {
            score -= 0.40
        }

        if requestedHasUppercase,
           reqWords.count == 1,
           titleWords.count >= 2,
           !biographyWords.isDisjoint(with: summaryWords),
           literaryRoleWords.isDisjoint(with: summaryWords),
           contextSummaryOverlap.isEmpty {
            score -= 0.32
        }

        if req.count <= 3 {
            score -= 0.20
        }

        // ── Entity-type mismatch penalty ──────────────────────────────────────────
        // Parse the Wikipedia extract's opening sentence to classify the article type,
        // then check if that type conflicts with what the phrase itself implies.
        // E.g. "Carl Johann Street" implies a place → penalise a person article.
        //      "Southern Seas" ends with a geographic word → penalise an entertainment article.
        let extractFirstSentence: String = {
            let raw = (extract ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.components(separatedBy: ".").first.map { $0.lowercased() } ?? ""
        }()

        enum ArticleEntityType { case place, person, entertainment, biology, unknown }

        let articleType: ArticleEntityType = {
            let s = extractFirstSentence
            let placeMarkers = ["is a street", "is the main street", "is a road", "is a boulevard",
                                "is a city", "is a town", "is a village", "is a municipality",
                                "is a country", "is a region", "is a mountain", "is a range",
                                "is a river", "is a lake", "is a bay", "is an island",
                                "is a park", "is a building", "is a church", "is a castle",
                                "is a shrine", "is a palace", "is located in", "is situated in",
                                "is a district", "is a neighbourhood", "is a neighborhood",
                                "is a peninsula", "is a port", "is a harbour", "is a harbor",
                                "is a plantation", "is an estate", "is a gate", "is a square"]
            let entertainmentMarkers = ["is a song", "is an album", "is a film", "is a movie",
                                        "is a television", "is a video game", "is a 20",
                                        "is a 19", "is a kazakh", "is a german", "directed by"]
            let biologyMarkers = ["is a species", "is a genus", "is a family of",
                                  "is a snake", "is a bird", "is a fish", "is a plant",
                                  "is an insect", "is a mammal", "is a reptile"]
            if placeMarkers.contains(where: { s.contains($0) }) { return .place }
            if entertainmentMarkers.contains(where: { s.contains($0) }) { return .entertainment }
            if biologyMarkers.contains(where: { s.contains($0) }) { return .biology }
            // Person: "was a/an [role]" is the canonical Wikipedia biography opening
            if s.contains(" was a ") || s.contains(" was an ") { return .person }
            return .unknown
        }()

        // Infer the expected entity type from the phrase itself
        let phraseWords = req.split(separator: " ").map(String.init)
        let placePhraseSuffixes: Set<String> = [
            "street", "road", "avenue", "lane", "boulevard", "gate", "way", "drive", "path",
            "hill", "mountain", "mountains", "range", "river", "lake", "bay", "island",
            "valley", "park", "square", "bridge", "tower", "castle", "church", "palace",
            "sea", "seas", "ocean", "coast", "cape", "point", "port", "harbour", "harbor"
        ]
        let phraseImpliesPlace = phraseWords.last.map { placePhraseSuffixes.contains($0) } ?? false

        if phraseImpliesPlace {
            switch articleType {
            case .person:        score -= 0.45   // "Carl Johann Street" → Karl Kautsky (person)
            case .entertainment: score -= 0.40   // "Southern Seas" → Songs from the Southern Seas (film)
            case .biology:       score -= 0.35
            case .place, .unknown: break
            }
        }

        return max(0, min(1, score))
    }

    /// Expands leading honorific abbreviations for better title matching.
    /// Only fires when "st" is the FIRST word of a multi-word phrase (Saint, not Street).
    /// "St Olav's" → ["st olavs", "saint olavs"]
    /// "University St" → ["university st"]   (last-word "st" is Street, left unchanged)
    private static func honorificExpansions(_ normalized: String) -> [String] {
        let words = normalized.split(separator: " ").map(String.init)
        guard words.count >= 2, let first = words.first else { return [normalized] }
        let expansions: [String: String] = ["st": "saint", "dr": "doctor", "mt": "mount", "ft": "fort"]
        guard let expanded = expansions[first] else { return [normalized] }
        let expandedForm = ([expanded] + words.dropFirst()).joined(separator: " ")
        return [normalized, expandedForm]
    }

    private static func passesLexicalGate(
        requested: String,
        candidateTitle: String,
        snippet: String
    ) -> Bool {
        let req = normalize(requested)
        let normalizedTitle = normalize(candidateTitle)
        let normalizedSnippet = normalize(snippet)
        let reqWords = Set(req.split(separator: " ").map(String.init))
        let titleWords = Set(normalizedTitle.split(separator: " ").map(String.init))

        if normalizedTitle == req || normalizedTitle.contains(req) || req.contains(normalizedTitle) {
            return true
        }

        if !reqWords.intersection(titleWords).isEmpty {
            return true
        }

        // Try honorific expansion: "st olav" → "saint olav" so "Saint Olaf" passes gate
        for expanded in honorificExpansions(req) where expanded != req {
            let expandedWords = Set(expanded.split(separator: " ").map(String.init))
            if !expandedWords.intersection(titleWords).isEmpty { return true }
            if normalizedTitle.contains(expanded) || expanded.contains(normalizedTitle) { return true }
        }

        if reqWords.count == 1, let onlyWord = reqWords.first, normalizedSnippet.contains(onlyWord) {
            return true
        }

        // Snippet-based fallback for multi-word requests: a Brave snippet often contains
        // the requested phrase even when the canonical Wikipedia title diverges (e.g.
        // "Saint_Olaf" redirects to "Olaf II of Norway" whose title shares no words with
        // "St Olav's", but the snippet mentions "Olav").  Use singularized content words
        // so "olavs" ≈ "olav".
        if reqWords.count >= 2, !normalizedSnippet.isEmpty {
            let honorificPrefixes: Set<String> = ["st", "dr", "mt", "ft", "mr", "mrs", "ms"]
            let contentWords = Set(req.split(separator: " ").map { singularize(String($0)) })
                .subtracting(honorificPrefixes)
            let expContentWords = honorificExpansions(req).flatMap {
                $0.split(separator: " ").map { singularize(String($0)) }
            }
            let snippetWordsSing = Set(normalizedSnippet.split(separator: " ").map { singularize(String($0)) })
            if !contentWords.intersection(snippetWordsSing).isEmpty
                || !Set(expContentWords).subtracting(honorificPrefixes).intersection(snippetWordsSing).isEmpty {
                return true
            }
        }

        return false
    }

    private static func shouldCompareAgainstSearch(
        requested: String,
        title: String?,
        extract: String?,
        contextBefore: String?,
        contextAfter: String?
    ) -> Bool {
        let req = normalize(stripPossessive(requested.trimmingCharacters(in: .whitespacesAndNewlines)))
        let normalizedTitle = normalize(title ?? "")
        guard !req.isEmpty, !normalizedTitle.isEmpty, req != normalizedTitle else { return false }

        let reqWords = req.split(separator: " ").map(String.init)
        let titleWords = normalizedTitle.split(separator: " ").map(String.init)
        let reqWordSet = Set(reqWords)
        let titleWordSet = Set(titleWords)
        let contextWords = Set(
            normalize([contextBefore, contextAfter].compactMap { $0 }.joined(separator: " "))
                .split(separator: " ")
                .map(String.init)
        ).subtracting(stopWords)
        let summaryWords = Set(normalize(extract ?? "").split(separator: " ").map(String.init)).subtracting(stopWords)
        // Exclude the request words (and their singularized forms) from the overlap check —
        // they trivially appear in both the context and any article that mentions the term
        // (e.g. "university"+"street" in a street article), masking a true mismatch.
        let requestWords = Set(reqWords).union(Set(reqWords.map(singularize)))
        let overlap = contextWords.intersection(summaryWords).subtracting(requestWords)

        let containsRequest = normalizedTitle.contains(req)
            || req.contains(normalizedTitle)
            || (!reqWordSet.isEmpty && reqWordSet.isSubset(of: titleWordSet))
        guard containsRequest else { return false }

        let sportsWords: Set<String> = ["baseball", "basketball", "football", "club", "team", "league", "season", "player"]
        let biographyWords: Set<String> = ["actor", "actress", "politician", "rapper", "singer", "footballer", "cricketer", "minister", "coach", "player", "born"]
        let literaryRoleWords: Set<String> = ["poet", "writer", "author", "novelist", "philosopher", "critic", "theologian", "historian"]
        let placeWords: Set<String> = ["street", "boulevard", "avenue", "square", "commune", "district", "quarter", "neighborhood", "city", "town", "municipality", "norway", "denmark", "canada", "quebec", "montreal", "copenhagen", "oslo"]

        if !sportsWords.isDisjoint(with: summaryWords), overlap.isEmpty {
            return true
        }

        if reqWords.count == 1,
           titleWords.count >= 2,
           !biographyWords.isDisjoint(with: summaryWords),
           literaryRoleWords.isDisjoint(with: summaryWords),
           overlap.isEmpty {
            return true
        }

        if requested.contains { $0.isUppercase },
           overlap.isEmpty,
           !placeWords.isDisjoint(with: summaryWords),
           (titleWords.count > reqWords.count || reqWords.count == 1) {
            return true
        }

        return false
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "in", "on", "at", "to", "for",
        "is", "was", "are", "were", "be", "been", "has", "have", "had",
        "it", "its", "this", "that", "these", "those", "with", "by", "from",
        "as", "he", "she", "they", "his", "her", "their", "not", "but",
        "which", "who", "what", "when", "where", "how", "also", "such"
    ]

    // Extracts the parenthetical disambiguator from a title, e.g. "Mercury (planet)" → "planet".
    private static func extractParenthetical(_ s: String) -> String? {
        guard let open = s.lastIndex(of: "("),
              let close = s.lastIndex(of: ")"),
              open < close else { return nil }
        let inner = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    // Returns a search query enriched with key context words, used when resolving disambiguation.
    // Uses up to 4 meaningful words, preferring capitalized tokens (proper nouns) which give
    // stronger disambiguation signal than generic literary words.
    private static func contextAugmentedQuery(_ term: String, contextBefore: String?, contextAfter: String?) -> String? {
        let combined = [contextBefore, contextAfter].compactMap { $0 }.joined(separator: " ")
        guard !combined.isEmpty else { return nil }

        let termNorm = normalize(term)

        // Prefer capitalized words — they're usually proper nouns that disambiguate well.
        // E.g. for "Marlow" with context "Joseph Conrad …" we pick ["joseph","conrad"] before
        // generic words like "wandered" or "seaman".
        let capitalWords = combined
            .split(separator: " ").map(String.init)
            .filter { w in
                guard let first = w.first else { return false }
                return first.isUppercase && w.count > 3 && !stopWords.contains(w.lowercased())
            }
            .map { normalize($0) }
            .filter { !$0.isEmpty && $0 != termNorm }

        // Fall back to any meaningful words if no capitalized ones survived.
        let fallback = normalize(combined)
            .split(separator: " ").map(String.init)
            .filter { !stopWords.contains($0) && $0.count > 4 && $0 != termNorm }

        let words = capitalWords.isEmpty ? fallback : capitalWords
        guard !words.isEmpty else { return nil }
        return "\(term) \(words.prefix(4).joined(separator: " "))"
    }

    // Returns false for strings that are clearly OCR garbage and not worth querying.
    private static func looksQueryable(_ s: String) -> Bool {
        let letters = s.filter { $0.isLetter }
        guard letters.count >= 2 else { return false }
        let nonWhitespace = s.filter { !$0.isWhitespace }
        guard !nonWhitespace.isEmpty else { return false }
        // At least half of non-whitespace chars must be letters (filters "123 /B\\ foo")
        guard Double(letters.count) / Double(nonWhitespace.count) >= 0.5 else { return false }
        // Too many words → OCR grabbed running text, not a lookup term
        guard s.split(separator: " ").count <= 7 else { return false }
        return true
    }

    // Repairs common OCR line-break hyphenation artifacts before querying.
    // E.g. "inter-\nnational" → "international", soft hyphens removed.
    private static func repairHyphenation(_ s: String) -> String {
        var r = s.replacingOccurrences(of: "\u{00AD}", with: "") // soft hyphen
        r = r.replacingOccurrences(of: #"-[ \t\n\r]+"#, with: "", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalize(_ s: String) -> String {
        let t = s.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        return t.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined()
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
    }

    private static func commonPrefixLen(_ a: String, _ b: String) -> Int {
        let aa = Array(a)
        let bb = Array(b)
        let n = min(aa.count, bb.count)
        var i = 0
        while i < n, aa[i] == bb[i] { i += 1 }
        return i
    }

    private static func stripPossessive(_ s: String) -> String {
        if s.hasSuffix("'s") || s.hasSuffix("’s") {
            return String(s.dropLast(2))
        }
        return s
    }

    private static func singularize(_ s: String) -> String {
        guard s.count > 4 else { return s }
        if s.hasSuffix("ies") {
            return String(s.dropLast(3)) + "y"
        }
        if s.hasSuffix("ses") || s.hasSuffix("xes") || s.hasSuffix("zes") {
            return String(s.dropLast())
        }
        if s.hasSuffix("s"), !s.hasSuffix("ss") {
            return String(s.dropLast())
        }
        return s
    }

    private static func envValue(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        let env = loadDotEnv()
        guard let value = env[key], !value.isEmpty else { return nil }
        return value
    }

    private static func loadDotEnv() -> [String: String] {
        if let cached = envCache { return cached }

        let fm = FileManager.default
        let candidates = [
            fm.currentDirectoryPath + "/.env",
            fm.currentDirectoryPath + "/../.env",
            NSHomeDirectory() + "/Downloads/Summa-main/.env"
        ]

        for path in candidates {
            guard fm.fileExists(atPath: path),
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            var env: [String: String] = [:]
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty {
                    env[key] = value
                }
            }
            envCache = env
            return env
        }

        envCache = [:]
        return [:]
    }
}
