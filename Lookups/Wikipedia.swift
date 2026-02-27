import Foundation

enum Wikipedia {

    // Public entrypoint used by OverlayController
    static func lookup(
        _ term: String,
        contextBefore: String? = nil,
        contextAfter: String? = nil
    ) async -> WikiResult {

        let requested = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            return WikiResult(status: .error, requested: term, title: nil, extract: "No term.", pageURL: nil, thumbnailURL: nil, debug: nil)
        }

        // 1) Try summary directly
        if let direct = await fetchSummary(title: requested) {
            if direct.status == .ok { return direct }

            // If it's disambiguation, try resolve via search
            if direct.status == .disambiguation {
                let resolved = await resolveViaSearch(requested, contextBefore: contextBefore, contextAfter: contextAfter)
                return resolved ?? direct
            }

            // If not found, fall through to search
            if direct.status == .notFound {
                let resolved = await resolveViaSearch(requested, contextBefore: contextBefore, contextAfter: contextAfter)
                return resolved ?? direct
            }

            // error etc.
        }

        // 2) Fallback search
        return await resolveViaSearch(requested, contextBefore: contextBefore, contextAfter: contextAfter)
            ?? WikiResult(status: .notFound, requested: requested, title: nil, extract: "No Wikipedia page found.", pageURL: nil, thumbnailURL: nil, debug: "fallback search returned nil")
    }

    // MARK: - Summary (REST)

    private static func fetchSummary(title: String) async -> WikiResult? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let underscored = clean.replacingOccurrences(of: " ", with: "_")

        guard
            let encoded = underscored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ScreenGlossMVP/0.1 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1

            // Common non-200s: 404 not found
            guard code == 200 else {
                return WikiResult(
                    status: code == 404 ? .notFound : .error,
                    requested: clean,
                    title: nil,
                    extract: code == 404 ? "No Wikipedia page found." : "Wikipedia lookup failed (HTTP \(code)).",
                    pageURL: nil,
                    thumbnailURL: nil,
                    debug: "summary HTTP \(code) url=\(url.absoluteString) body=\(String(data: data, encoding: .utf8) ?? "")"
                )
            }

            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return WikiResult(status: .error, requested: clean, title: nil, extract: "Bad JSON.", pageURL: nil, thumbnailURL: nil, debug: "summary bad JSON")
            }

            let pageType = (obj["type"] as? String)?.lowercased() // e.g. "standard" or "disambiguation"
            let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let extract = (obj["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            let contentURLs = obj["content_urls"] as? [String: Any]
            let desktop = contentURLs?["desktop"] as? [String: Any]
            let pageURL = (desktop?["page"] as? String)

            let thumb = obj["thumbnail"] as? [String: Any]
            let thumbURL = thumb?["source"] as? String

            // Heuristic disambiguation detect (in case type missing)
            let isDisamb = (pageType == "disambiguation")
                || ((extract ?? "").contains("may refer to"))

            return WikiResult(
                status: isDisamb ? .disambiguation : .ok,
                requested: clean,
                title: title,
                extract: extract ?? (isDisamb ? "This term is ambiguous." : nil),
                pageURL: pageURL,
                thumbnailURL: thumbURL,
                debug: isDisamb ? "disambiguation detected via type/extract" : nil
            )
        } catch {
            return WikiResult(
                status: .error,
                requested: clean,
                title: nil,
                extract: "Wikipedia lookup failed: \(error.localizedDescription)",
                pageURL: nil,
                thumbnailURL: nil,
                debug: "summary error \(error)"
            )
        }
    }

    // MARK: - Search (MediaWiki API) + resolve

    private static func resolveViaSearch(
        _ term: String,
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
                return WikiResult(status: .error, requested: q, title: nil, extract: "Wikipedia search failed (HTTP \(code)).", pageURL: nil, thumbnailURL: nil, debug: "search HTTP \(code)")
            }

            guard
                let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let query = obj["query"] as? [String: Any],
                let search = query["search"] as? [[String: Any]]
            else {
                return WikiResult(status: .error, requested: q, title: nil, extract: "Wikipedia search JSON parse failed.", pageURL: nil, thumbnailURL: nil, debug: "search parse fail")
            }

            let titles: [String] = search.compactMap { $0["title"] as? String }
            guard !titles.isEmpty else {
                return WikiResult(status: .notFound, requested: q, title: nil, extract: "No Wikipedia page found.", pageURL: nil, thumbnailURL: nil, debug: "search empty")
            }

            // Pick best by context overlap + string similarity
            let chosen = chooseBestTitle(
                requested: q,
                candidates: titles,
                contextBefore: contextBefore,
                contextAfter: contextAfter
            )

            // Fetch summary for chosen title
            if let resolved = await fetchSummary(title: chosen) {
                // If STILL disambiguation, take top candidate’s summary anyway and label as disambiguation
                return resolved
            }

            return WikiResult(status: .error, requested: q, title: chosen, extract: "Failed to resolve Wikipedia page.", pageURL: nil, thumbnailURL: nil, debug: "resolved title but summary nil")
        } catch {
            return WikiResult(status: .error, requested: q, title: nil, extract: "Wikipedia search failed: \(error.localizedDescription)", pageURL: nil, thumbnailURL: nil, debug: "search error \(error)")
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

    private static func chooseBestTitle(
        requested: String,
        candidates: [String],
        contextBefore: String?,
        contextAfter: String?
    ) -> String {
        let req = normalize(requested)
        let ctx = normalize([contextBefore, contextAfter].compactMap { $0 }.joined(separator: " "))

        func score(_ title: String) -> Int {
            let t = normalize(title)

            // base: similarity to requested
            var s = 0
            s += 50 - abs(t.count - req.count)
            s += commonPrefixLen(t, req) * 4
            if t == req { s += 50 }
            if t.contains(req) || req.contains(t) { s += 20 }

            // context overlap
            if !ctx.isEmpty {
                let ctxWords = Set(ctx.split(separator: " ").map(String.init))
                let titleWords = Set(t.split(separator: " ").map(String.init))
                s += Set(ctxWords).intersection(titleWords).count * 6
            }

            return s
        }

        return candidates.max(by: { score($0) < score($1) }) ?? candidates[0]
    }

    private static func normalize(_ s: String) -> String {
        let t = s.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // keep letters/numbers/spaces only
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
}
