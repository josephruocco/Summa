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
        contextAfter: String? = nil
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
                    let scoreBar = max(0.62, directScore + 0.05)

                    // 1. Try Wikipedia keyword search
                    if let resolved = await resolveViaSearch(searchTerm, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter),
                       let resolvedScore = resolved.score,
                       resolved.status == .ok,
                       resolvedScore >= scoreBar {
                        return resolved
                    }
                    // 2. Wikipedia search missed — try Bing (scoped to en.wikipedia.org)
                    if let bingResult = await resolveViaBingSearch(searchTerm, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter),
                       let bingScore = bingResult.score,
                       bingResult.status == .ok,
                       bingScore >= scoreBar {
                        return bingResult
                    }
                }

                if !suspiciousDirect,
                   let accepted = verify(result: direct, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                    return accepted
                }

                if direct.status == .disambiguation {
                    hitDisambiguation = true
                    let searchTerm = contextAugmentedQuery(query, contextBefore: contextBefore, contextAfter: contextAfter) ?? query
                    let resolved = await resolveViaSearch(searchTerm, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter)
                    if let resolved, let accepted = verify(result: resolved, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                        return accepted
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
        let looksLikeMeaningfulPhrase = requested.contains(" ")
            && requested.split(separator: " ").count >= 3
        if allBaseNotFound && looksLikeMeaningfulPhrase {
            for query in phraseSearchQueries(for: requested) {
                if let resolved = await resolveViaSearch(query, requested: query, contextBefore: contextBefore, contextAfter: contextAfter) {
                    if resolved.status == .ok, let s = resolved.score, s >= 0.62 {
                        var accepted = resolved
                        accepted.requested = requested
                        return accepted
                    }
                    if let accepted = verify(result: resolved, requested: query, contextBefore: contextBefore, contextAfter: contextAfter) {
                        var rebound = accepted
                        rebound.requested = requested
                        return rebound
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
            // For single proper nouns that caused disambiguation we use a context-augmented
            // query — capitalised words from the wider context (author name, nearby proper
            // nouns) anchor the search to the right sense without pulling in generic literary
            // words.  For silent redirects and non-proper-noun terms we keep the bare query
            // since Wikipedia's own relevance ranking works better there (adding noise words
            // to e.g. "Ylajali" causes it to match unrelated articles).
            let searchTerm: String
            if hitDisambiguation {
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
                // score resolveViaSearch already set if it meets the acceptance threshold.
                if resolved.status == .ok, let s = resolved.score, s >= 0.62 {
                    return resolved
                }
                if let accepted = verify(result: resolved, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                    return accepted
                }
                if resolved.status == .ok {
                    return suppress(result: resolved, reason: "fallback search result scored too low")
                }
                return resolved
            }
        }

        // Cache terms that had no Wikipedia article at any variant so we don't re-query them
        if allBaseNotFound {
            notFoundCache.insert(cacheKey)
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
            let topCandidates = Array(ranked.prefix(3))
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

            guard (best.score ?? 0) >= 0.58 else {
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

    // MARK: - Bing Web Search fallback

    /// Calls the Bing Web Search API scoped to en.wikipedia.org, extracts Wikipedia article
    /// titles from the result URLs, and scores each via the existing `scoreCandidate` pipeline.
    /// Returns nil when no key is configured or no candidate clears the threshold.
    private static func resolveViaBingSearch(
        _ term: String,
        requested: String,
        contextBefore: String?,
        contextAfter: String?
    ) async -> WikiResult? {
        guard let apiKey = ProcessInfo.processInfo.environment["BING_SEARCH_API_KEY"],
              !apiKey.isEmpty else { return nil }

        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        let encodedQuery = "\(q) site:en.wikipedia.org"
        var comps = URLComponents(string: "https://api.bing.microsoft.com/v7.0/search")!
        comps.queryItems = [
            URLQueryItem(name: "q",          value: encodedQuery),
            URLQueryItem(name: "count",      value: "8"),
            URLQueryItem(name: "mkt",        value: "en-US"),
            URLQueryItem(name: "responseFilter", value: "Webpages"),
        ]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(apiKey,              forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        req.setValue("application/json",  forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            guard let obj       = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let webPages  = obj["webPages"] as? [String: Any],
                  let value     = webPages["value"] as? [[String: Any]]
            else { return nil }

            // Extract Wikipedia article titles from result URLs
            // e.g. https://en.wikipedia.org/wiki/Universitetsplassen → "Universitetsplassen"
            var candidates: [SearchCandidate] = []
            for entry in value {
                guard let urlStr  = entry["url"]     as? String,
                      let name    = entry["name"]     as? String,
                      urlStr.hasPrefix("https://en.wikipedia.org/wiki/") else { continue }
                let rawSlug   = urlStr.replacingOccurrences(of: "https://en.wikipedia.org/wiki/", with: "")
                let title     = rawSlug
                    .removingPercentEncoding?
                    .replacingOccurrences(of: "_", with: " ")
                    ?? name
                let snippet   = (entry["snippet"] as? String) ?? ""
                candidates.append(SearchCandidate(title: title, snippet: snippet))
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
            guard !resolved.isEmpty else { return nil }

            let sorted = resolved.sorted { $0.1 > $1.1 }
            let best   = sorted[0].0
            guard (best.score ?? 0) >= 0.58, best.status == .ok else { return nil }
            return best

        } catch {
            return nil
        }
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

        guard score >= 0.62 else { return nil }

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

        var seen = Set<String>()
        return [requested, normalized, repaired, strippedPossessive, singular]
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
        let normalizedTitle = normalize(title ?? "")
        let context = normalize([contextBefore, contextAfter].compactMap { $0 }.joined(separator: " "))
        let summary = normalize([snippet, extract].compactMap { $0 }.joined(separator: " "))

        var score = 0.0

        if normalizedTitle == req, !req.isEmpty {
            score += 0.42
        } else if normalizedTitle.hasPrefix(req) || normalizedTitle.contains(req) || req.contains(normalizedTitle) {
            score += 0.24
        } else {
            score -= 0.12
        }

        score += min(0.18, Double(commonPrefixLen(normalizedTitle, req)) * 0.03)

        let reqWordList = req.split(separator: " ").map(String.init)
        let titleWordList = normalizedTitle.split(separator: " ").map(String.init)
        let reqWords = Set(reqWordList)
        let titleWords = Set(titleWordList)
        let singularReqWords = Set(reqWordList.map(singularize))
        let singularTitleWords = Set(titleWordList.map(singularize))
        let summaryWords = Set(summary.split(separator: " ").map(String.init))
        let titleOverlap = reqWords.intersection(titleWords).count
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
        let isAliasMatch = requestedHasUppercase
            && !req.contains(" ")
            && !req.isEmpty
            && titleOverlap == 0
            && (summaryWords.contains(req) || rawBodyWords.contains(req))

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

        if requestedHasUppercase, reqWords.count == 1, titleOverlap > 0, titleWords.count >= 2 {
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
                    score -= 0.12
                }
            }
        }

        // "List of X" articles are never useful for contextual lookups.
        if normalizedTitle.hasPrefix("list of") {
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

        // "Named-after" penalty: single-word query where the title starts with the exact
        // term but has additional words (e.g. "Christiania Spigerverk" for "Christiania").
        // These articles are named after the place/person, not the canonical article about it.
        if !req.contains(" "), !req.isEmpty,
           normalizedTitle.hasPrefix(req + " "),
           titleWords.count >= 2 {
            score -= 0.18
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

        return max(0, min(1, score))
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

        if reqWords.count == 1, let onlyWord = reqWords.first, normalizedSnippet.contains(onlyWord) {
            return true
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
}
