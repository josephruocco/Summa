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

        for query in retryQueries(for: requested) {
            if let direct = await fetchSummary(title: query) {
                if let accepted = verify(result: direct, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                    return accepted
                }

                if direct.status == .disambiguation || direct.status == .notFound {
                    let resolved = await resolveViaSearch(query, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter)
                    if let resolved, let accepted = verify(result: resolved, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                        return accepted
                    }
                    if let resolved, resolved.status == .ok {
                        return suppress(result: resolved, reason: "search result scored too low")
                    }
                } else if direct.status == .ok {
                    return suppress(result: direct, reason: "direct result scored too low")
                }
            }
        }

        if let resolved = await resolveViaSearch(requested, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
            if let accepted = verify(result: resolved, requested: requested, contextBefore: contextBefore, contextAfter: contextAfter) {
                return accepted
            }
            if resolved.status == .ok {
                return suppress(result: resolved, reason: "fallback search result scored too low")
            }
            return resolved
        }

        return WikiResult(
            status: .notFound,
            requested: requested,
            title: nil,
            extract: "No Wikipedia page found.",
            pageURL: nil,
            thumbnailURL: nil,
            debug: "fallback search returned nil",
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
            let isDisamb = (pageType == "disambiguation") || ((extract ?? "").contains("may refer to"))

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

            let sorted = resolved.sorted { lhs, rhs in lhs.1 > rhs.1 }
            let best = sorted[0].0
            let margin = sorted.count > 1 ? sorted[0].1 - sorted[1].1 : sorted[0].1

            if best.status == .disambiguation {
                return suppress(result: best, reason: "top candidate remained disambiguation")
            }

            guard (best.score ?? 0) >= 0.58 else {
                return suppress(result: best, reason: "best search candidate below threshold")
            }

            guard margin >= 0.08 else {
                return suppress(result: best, reason: "search candidates too close")
            }

            return best
        } catch {
            return WikiResult(status: .error, requested: q, title: nil, extract: "Wikipedia search failed: \(error.localizedDescription)", pageURL: nil, thumbnailURL: nil, debug: "search error \(error)", score: nil)
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
        let strippedPossessive = stripPossessive(normalized)
        let singular = singularize(strippedPossessive)

        var seen = Set<String>()
        return [requested, normalized, strippedPossessive, singular]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert(normalize($0)).inserted }
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
        let req = normalize(requested)
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
        score -= min(0.12, Double(abs(normalizedTitle.count - req.count)) * 0.01)

        let reqWords = Set(req.split(separator: " ").map(String.init))
        let titleWords = Set(normalizedTitle.split(separator: " ").map(String.init))
        let summaryWords = Set(summary.split(separator: " ").map(String.init))
        let titleOverlap = reqWords.intersection(titleWords).count
        let summaryOverlap = reqWords.intersection(summaryWords).count
        let requestedHasUppercase = requested.contains { $0.isUppercase }

        if !reqWords.isEmpty {
            score += Double(titleOverlap) * 0.12
            score += Double(summaryOverlap) * 0.05
        }

        if titleOverlap == 0, !normalizedTitle.contains(req), !req.contains(normalizedTitle) {
            score -= 0.35
        }

        if requestedHasUppercase, reqWords.count == 1, titleOverlap > 0, titleWords.count >= 2 {
            score += 0.24
        }

        if !context.isEmpty {
            let contextWords = Set(context.split(separator: " ").map(String.init))
            score += min(0.20, Double(contextWords.intersection(summaryWords).count) * 0.05)
            score += min(0.10, Double(contextWords.intersection(titleWords).count) * 0.05)
        }

        let loweredSummary = summary.lowercased()
        if loweredSummary.contains("may refer to") || loweredSummary.contains("can refer to") {
            score -= 0.45
        }

        if status == .disambiguation {
            score -= 0.45
        }

        if !requestedHasUppercase && (titleWords.count >= 2 || loweredSummary.contains("born")) {
            score -= 0.18
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

    private static func normalize(_ s: String) -> String {
        let t = s.lowercased()
            .replacingOccurrences(of: "_", with: " ")
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
