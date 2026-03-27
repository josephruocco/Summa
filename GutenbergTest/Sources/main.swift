import Foundation

// MARK: - Common words loader

enum CommonWordsLoader {
    static var set: Set<String> = {
        guard let url = Bundle.module.url(forResource: "common_words_en_20k", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            fputs("Warning: could not load common_words_en_20k.txt\n", stderr)
            return []
        }
        return Set(
            text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        )
    }()
}

// MARK: - Gutenberg fetcher

// Free Dictionary API — returns a plain definition string or nil
func fetchDefinition(_ word: String) async -> String? {
    let lower = word.lowercased()
    guard let encoded = lower.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
          let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)")
    else { return nil }
    var req = URLRequest(url: url); req.timeoutInterval = 6
    req.setValue("GutenbergTest/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
          let entry = json.first,
          let meanings = entry["meanings"] as? [[String: Any]],
          let meaning = meanings.first,
          let defs = meaning["definitions"] as? [[String: Any]],
          let defText = defs.first?["definition"] as? String
    else { return nil }

    let pos = (meaning["partOfSpeech"] as? String) ?? ""
    let phonetics = (entry["phonetics"] as? [[String: Any]])?
        .compactMap { $0["text"] as? String }.first ?? ""
    let phonPart = phonetics.isEmpty ? "" : "| \(phonetics) | "
    return "\(word) | \(phonPart)\(pos) \(defText)"
}

struct GutenbergSource {
    let chapterHTML: String   // inner HTML to embed in demo (proper <p> tags etc.)
    let plainText: String     // for tokenization / Wikipedia lookup
}

func fetchGutenberg(spec: BookSpec) async throws -> GutenbergSource {
    return try await fetchGutenbergInner(bookID: spec.id, chapterDivIndex: spec.chapterDivIndex,
                                         startAnchor: spec.startAnchor, endAnchor: spec.endAnchor)
}

private func fetchGutenbergInner(bookID: Int, chapterDivIndex: Int?, startAnchor: String?, endAnchor: String?) async throws -> GutenbergSource {
    // Try HTML version first — it has proper paragraph/heading markup
    let htmlURLs = [
        "https://www.gutenberg.org/cache/epub/\(bookID)/pg\(bookID)-images.html",
        "https://www.gutenberg.org/files/\(bookID)/\(bookID)-h/\(bookID)-h.htm",
    ]
    for urlString in htmlURLs {
        guard let url = URL(string: urlString) else { continue }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        req.setValue("GutenbergTest/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { continue }

        // Anchor-based extraction (e.g. Moby-Dick chapter IDs)
        if let start = startAnchor {
            let startTag = "id=\"\(start)\""
            guard let startRange = html.range(of: startTag) else { continue }
            // Walk back to the block-level opening '<' so we don't start mid-element.
            // Anchors are often inside inline <a> tags nested inside <h2>/<p>, so we
            // skip past any inline tag we land on to find the real container.
            let before = html[html.startIndex..<startRange.lowerBound]
            var from = before.lastIndex(of: "<") ?? startRange.lowerBound
            let inlineOpenings = ["<a ", "<a\t", "<a\n", "<a>", "<em", "<span", "<strong", "<b ", "<i "]
            if inlineOpenings.contains(where: { html[from...].hasPrefix($0) }) {
                let beforeInline = html[html.startIndex..<from]
                from = beforeInline.lastIndex(of: "<") ?? from
            }
            let slice: String
            if let end = endAnchor, let endRange = html.range(of: "id=\"\(end)\"", range: from..<html.endIndex) {
                slice = String(html[from..<endRange.lowerBound])
            } else {
                slice = String(html[from...])
            }
            let chHTML = slice
            var plain = chHTML
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&mdash;", with: "—")
                .replacingOccurrences(of: "&ndash;", with: "–").replacingOccurrences(of: "&rsquo;", with: "\u{2019}")
                .replacingOccurrences(of: "&lsquo;", with: "\u{2018}").replacingOccurrences(of: "&ldquo;", with: "\u{201C}")
                .replacingOccurrences(of: "&rdquo;", with: "\u{201D}")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return GutenbergSource(chapterHTML: chHTML, plainText: plain)
        }

        // Extract chapter divs
        let pattern = #"<div class="chapter">(.*?)</div><!--end chapter-->"#
        let chapters = html.matches(pattern: pattern, group: 1)
        guard !chapters.isEmpty else { continue }
        let idx = min(chapterDivIndex ?? 0, chapters.count - 1)
        let chHTML = chapters[idx]

        // Plain text: strip tags
        var plain = chHTML
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&rsquo;", with: "\u{2019}")
            .replacingOccurrences(of: "&lsquo;", with: "\u{2018}")
            .replacingOccurrences(of: "&ldquo;", with: "\u{201C}")
            .replacingOccurrences(of: "&rdquo;", with: "\u{201D}")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return GutenbergSource(chapterHTML: chHTML, plainText: plain)
    }

    // Fallback to plain text
    let txtURLs = [
        "https://www.gutenberg.org/files/\(bookID)/\(bookID)-0.txt",
        "https://www.gutenberg.org/files/\(bookID)/\(bookID).txt",
        "https://www.gutenberg.org/cache/epub/\(bookID)/pg\(bookID).txt"
    ]
    var lastError: Error?
    for urlString in txtURLs {
        guard let url = URL(string: urlString) else { continue }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        req.setValue("GutenbergTest/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { continue }
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                let body = skipToChapter(cleanGutenbergText(stripBoilerplate(normalized)))
                return GutenbergSource(chapterHTML: plainToHTML(body), plainText: body)
            }
        } catch { lastError = error }
    }
    throw lastError ?? URLError(.resourceUnavailable)
}

extension String {
    func matches(pattern: String, group: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > group else { return nil }
            let r = m.range(at: group)
            guard r.location != NSNotFound else { return nil }
            return ns.substring(with: r)
        }
    }
}

func plainToHTML(_ text: String) -> String {
    text.components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { block -> String in
            let line = block.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let isHeading = line.count < 80 && line == line.uppercased() && line.filter(\.isLetter).count > 2
            return isHeading ? "<h2>\(line)</h2>" : "<p>\(line)</p>"
        }
        .joined(separator: "\n")
}

// Skips long prefaces/introductions by finding the first chapter/part heading,
// then advances past the heading line itself to the actual prose.
func skipToChapter(_ text: String) -> String {
    let patterns = [
        #"(?m)^(CHAPTER|Chapter|PART|Part)\s+(I|1|ONE|II|2|TWO)\b"#,
        #"(?m)^\s*I\.\s*$"#,
        #"(?m)^[IVX]{1,4}\.\s*$"#,
    ]
    for pattern in patterns {
        if let range = text.range(of: pattern, options: .regularExpression) {
            // Skip past the heading line and any blank lines after it
            let afterHeading = text[range.upperBound...]
            if let nextContent = afterHeading.range(of: #"\n\n+"#, options: .regularExpression) {
                return String(text[nextContent.upperBound...])
            }
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return text
}

// Strip Gutenberg italic markers (_word_) and other markup artifacts.
func cleanGutenbergText(_ text: String) -> String {
    var s = text
    // _word_ → word (italic markers)
    s = s.replacingOccurrences(of: #"_([^_]+)_"#, with: "$1", options: .regularExpression)
    // Remove asterisk emphasis
    s = s.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
    // Collapse runs of spaces/stars used as section dividers
    s = s.replacingOccurrences(of: #"(?m)^\s*\*\s*\*\s*\*\s*$"#, with: "", options: .regularExpression)
    return s
}

func stripBoilerplate(_ text: String) -> String {
    // Strip UTF-8 BOM if present
    var body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text

    let startMarkers = ["*** START OF THE PROJECT GUTENBERG", "*** START OF THIS PROJECT GUTENBERG"]
    let endMarkers   = ["*** END OF THE PROJECT GUTENBERG",   "*** END OF THIS PROJECT GUTENBERG"]

    for marker in startMarkers {
        if let range = body.range(of: marker, options: .caseInsensitive) {
            // Skip to the end of the *** ... *** line
            let afterMarker = body[range.upperBound...]
            if let nl = afterMarker.firstIndex(of: "\n") {
                body = String(body[body.index(after: nl)...])
            }
            break
        }
    }
    for marker in endMarkers {
        if let range = body.range(of: marker, options: .caseInsensitive) {
            body = String(body[..<range.lowerBound]); break
        }
    }
    return body.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Demo site output

struct DemoAnnotation: Encodable {
    let id: String
    let kind: String
    let surface: String
    let span: Span
    let confidence: Double
    let payload: Payload

    struct Span: Encodable { let start: Int; let end: Int }

    struct Payload: Encodable {
        let summary: String?
        let wikiTitle: String?
        // Vocab only
        let dictionary: DictPayload?

        // Custom encoding so nil fields are omitted entirely
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let summary  { try c.encode(summary,   forKey: .summary) }
            if let wikiTitle { try c.encode(wikiTitle, forKey: .wikiTitle) }
            if let dictionary { try c.encode(dictionary, forKey: .dictionary) }
        }
        enum CodingKeys: String, CodingKey { case summary, wikiTitle, dictionary }
    }

    struct DictPayload: Encodable {
        let definition: String
        let headword: String
    }
}

struct DemoCatalog: Encodable {
    let schema_version: String
    let source: Source
    let annotations: [DemoAnnotation]

    struct Source: Encodable {
        let title: String
        let createdAtISO8601: String
        let textLength: Int
        let generator: String
    }
}

func chapterHTML(title: String, innerHTML: String) -> String {
    let esc = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
    return """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>\(esc)</title>
      <link rel="stylesheet" href="../../styles.css" />
    </head>
    <body>
      <header class="topbar">
        <a class="brand" href="../../index.html">SUMMA demos</a>
      </header>
      <main id="text" class="chapter">
    \(innerHTML)
    <br/><br/><br/><br/>
    <div id="mood-orb-root" style="display: block;"></div>
      </main>
      <div id="summa-tooltip" class="summa-tooltip" hidden></div>
      <script src="../../app.js"></script>
    </body>
    </html>
    """
}

func findSpan(of term: String, in text: String, after offset: String.Index) -> (start: Int, end: Int, next: String.Index)? {
    let searchRange = offset..<text.endIndex
    guard let range = text.range(of: term, options: [.caseInsensitive], range: searchRange) else { return nil }
    let start = text.distance(from: text.startIndex, to: range.lowerBound)
    let end = text.distance(from: text.startIndex, to: range.upperBound)
    return (start, end, range.upperBound)
}

// MARK: - TSV report helpers

func log(_ msg: String) { fputs(msg + "\n", stderr) }

func tsvEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ")
     .replacingOccurrences(of: "\n", with: " ")
     .replacingOccurrences(of: "\r", with: "")
}

// MARK: - Main

struct BookSpec {
    let id: Int
    let title: String
    let slug: String
    let chapterTitle: String
    let maxChars: Int
    // HTML extraction hints — use one of these or fall back to plain text
    let chapterDivIndex: Int?   // index into <div class="chapter"> elements
    let startAnchor: String?    // id="..." anchor to slice from (for anchor-based books)
    let endAnchor: String?      // id="..." anchor to slice to (optional)

    init(id: Int, title: String, slug: String, chapterTitle: String, maxChars: Int,
         chapterDivIndex: Int? = nil, startAnchor: String? = nil, endAnchor: String? = nil) {
        self.id = id; self.title = title; self.slug = slug
        self.chapterTitle = chapterTitle; self.maxChars = maxChars
        self.chapterDivIndex = chapterDivIndex
        self.startAnchor = startAnchor; self.endAnchor = endAnchor
    }
}

let defaultBooks: [BookSpec] = [
    // Hunger: <div class="chapter"> index 2 = Part I (skips edition note + intro)
    BookSpec(id: 8387, title: "Hunger",                     slug: "hunger_ch01",
             chapterTitle: "Hunger — Knut Hamsun",              maxChars: 0, chapterDivIndex: 2),
    // Moby-Dick: Chapter 42 "The Whiteness of the Whale"
    BookSpec(id: 2701, title: "Moby-Dick",                  slug: "md_ch42",
             chapterTitle: "Moby-Dick, Chapter 42 — Herman Melville", maxChars: 0,
             startAnchor: "link2HCH0042", endAnchor: "link2HCH0043"),
    // Crime and Punishment: Part I Chapter I (Raskolnikov leaving his garret)
    BookSpec(id: 2554, title: "Crime and Punishment",       slug: "cap_ch01",
             chapterTitle: "Crime and Punishment, Part I Chapter I — Dostoevsky", maxChars: 0,
             startAnchor: "link2HCH0001", endAnchor: "link2HCH0002"),
    // Heart of Darkness: opening on the Nellie through to Marlow beginning his Congo account
    BookSpec(id: 526,  title: "Heart of Darkness",          slug: "hod_full",
             chapterTitle: "Heart of Darkness — Joseph Conrad",  maxChars: 0,
             startAnchor: "id00005", endAnchor: "id00019"),
    // Dorian Gray: Chapter I (Basil's studio, first meeting with Lord Henry)
    BookSpec(id: 174,  title: "The Picture of Dorian Gray", slug: "dg_ch01",
             chapterTitle: "The Picture of Dorian Gray, Chapter I — Oscar Wilde", maxChars: 0,
             startAnchor: "chap01", endAnchor: "chap02"),
    // Wuthering Heights: Chapter I (Lockwood visits Wuthering Heights, meets Heathcliff)
    BookSpec(id: 768,  title: "Wuthering Heights",          slug: "wh_ch01",
             chapterTitle: "Wuthering Heights, Chapter I — Emily Brontë",         maxChars: 0,
             chapterDivIndex: 0),
    // Beyond Good and Evil: Part One — On the Prejudices of Philosophers
    BookSpec(id: 4363, title: "Beyond Good and Evil",       slug: "bge_ch01",
             chapterTitle: "Beyond Good and Evil, Part I — Friedrich Nietzsche",  maxChars: 0,
             startAnchor: "link2HCH0001", endAnchor: "link2HCH0002"),
    // Montaigne: Of Experience (Essays, Book III, Chapter XIII)
    BookSpec(id: 3600, title: "Of Experience",              slug: "e_oe",
             chapterTitle: "Of Experience — Michel de Montaigne",                 maxChars: 0,
             startAnchor: "link2HCH0106", endAnchor: "link2H_4_0128"),
    // Pride and Prejudice: Chapter I
    BookSpec(id: 1342, title: "Pride and Prejudice",        slug: "pp_ch01",
             chapterTitle: "Pride and Prejudice, Chapter I — Jane Austen",        maxChars: 0,
             startAnchor: "Chapter_I", endAnchor: "CHAPTER_II"),
]

let args = Array(CommandLine.arguments.dropFirst())
let demoMode = args.contains("--demo")

// First non-flag arg that looks like a path is the output dir; remaining numeric args are book IDs
let nonFlags = args.filter { !$0.hasPrefix("-") }
let demoOutputDir: String = nonFlags.first(where: { $0.contains("/") }) ?? "/Users/josephruocco/summa_site/demos"
let requestedIDs = Set(nonFlags.compactMap { Int($0) })
let bookList = requestedIDs.isEmpty ? defaultBooks : defaultBooks.filter { requestedIDs.contains($0.id) }

let maxRefsPerBook  = 40
let maxVocabPerBook = 30
let commonWords = CommonWordsLoader.set

// MARK: - Score tracking

struct BookRunStats {
    let slug: String
    var ok        = 0
    var notFound  = 0
    var suppressed = 0
    var scoreSum  = 0.0
    var scoreCount = 0

    var total: Int { ok + notFound + suppressed }
    var okPct: Double { total > 0 ? Double(ok) / Double(total) * 100 : 0 }
    var avgScore: Double { scoreCount > 0 ? scoreSum / Double(scoreCount) : 0 }
}

var allBookStats: [BookRunStats] = []

if !demoMode {
    // TSV mode
    print(["bookID","bookTitle","phrase","kind","status","wikiTitle","score","extract","debug"]
        .joined(separator: "\t"))
}

for book in bookList {
    log("── \(book.title) (ID \(book.id))")
    let source: GutenbergSource
    do { source = try await fetchGutenberg(spec: book) }
    catch { log("  ✗ Download failed: \(error.localizedDescription)"); continue }

    // Trim plain text to maxChars for lookup (not for HTML — keep full chapter)
    var text = source.plainText
    if book.maxChars > 0, text.count > book.maxChars {
        let idx = text.index(text.startIndex, offsetBy: min(book.maxChars, text.count))
        if let paraEnd = text[idx...].range(of: ". ") {
            text = String(text[..<paraEnd.upperBound])
        } else {
            text = String(text[..<idx])
        }
    }
    log("  \(text.split(separator: " ").count) words")

    let tokens = Tokenizer.tokenize(text)
    let allCandidates = Tokenizer.extractCandidates(from: tokens, commonWords: commonWords)
    let refs   = Array(allCandidates.filter { $0.kind == .reference }.prefix(maxRefsPerBook))
    let vocabs = Array(allCandidates.filter { $0.kind == .vocab      }.prefix(maxVocabPerBook))

    log("  \(refs.count) ref candidates → Wikipedia lookups, \(vocabs.count) vocab → dictionary")

    // Book-level disambiguation context: prepend author name + distinctive title words to
    // every lookup so character names like "Marlow" (Conrad) or "Raskolnikov" (Dostoevsky)
    // resolve to the correct article rather than an unrelated person.
    //
    // We filter the book title to words ≥7 chars so generic short words like "Hunger",
    // "Crime", "Heart" don't spill into unrelated articles, while keeping distinctive words
    // like "Darkness", "Punishment", "Picture" that appear in the canonical article text.
    let chapterParts = book.chapterTitle.components(separatedBy: " — ")
    let authorName = chapterParts.count > 1 ? chapterParts.last! : ""
    let titleDistinctive = book.title
        .split(separator: " ").map(String.init)
        .filter { $0.count >= 7 && !["chapter","section","prologue","epilogue"].contains($0.lowercased()) }
        .joined(separator: " ")
    let docContext = [titleDistinctive, authorName].filter { !$0.isEmpty }.joined(separator: " ")

    var bookStats = BookRunStats(slug: book.slug)
    var annotations: [DemoAnnotation] = []
    var seenTerms = Set<String>()
    for candidate in refs {
        guard seenTerms.insert(candidate.phrase.lowercased()).inserted else { continue }

        let enrichedBefore = [docContext, candidate.contextBefore]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let result = await Wikipedia.lookup(
            candidate.phrase,
            contextBefore: enrichedBefore.isEmpty ? nil : enrichedBefore,
            contextAfter:  candidate.contextAfter.isEmpty  ? nil : candidate.contextAfter
        )

        let icon = result.status == .ok ? "✓" : (result.status == .suppressed ? "~" : "✗")
        log("  \(icon) \(candidate.phrase) → \(result.status.rawValue) \(result.title.map { "[\($0)]" } ?? "") \(result.score.map { String(format: "%.2f", $0) } ?? "")")

        switch result.status {
        case .ok:
            bookStats.ok += 1
            if let s = result.score { bookStats.scoreSum += s; bookStats.scoreCount += 1 }
        case .notFound, .error:
            bookStats.notFound += 1
        case .suppressed:
            bookStats.suppressed += 1
        }

        if !demoMode {
            print([
                String(book.id),
                tsvEscape(book.title),
                tsvEscape(candidate.phrase),
                "ref",
                result.status.rawValue,
                tsvEscape(result.title ?? ""),
                result.score.map { String(format: "%.2f", $0) } ?? "",
                tsvEscape(String((result.extract ?? "").prefix(120))),
                tsvEscape(result.debug ?? "")
            ].joined(separator: "\t"))
        }

        if demoMode, result.status == .ok {
            if let spanInfo = findSpan(of: candidate.phrase, in: text, after: text.startIndex) {
                let score = result.score ?? 0.0
                let confidence = score >= 0.85 ? 0.99 : 0.79
                let ann = DemoAnnotation(
                    id: "r|\(candidate.phrase.lowercased().replacingOccurrences(of: " ", with: "_"))",
                    kind: "reference",
                    surface: candidate.phrase,
                    span: DemoAnnotation.Span(start: spanInfo.start, end: spanInfo.end),
                    confidence: confidence,
                    payload: DemoAnnotation.Payload(
                        summary: result.extract,
                        wikiTitle: result.title,
                        dictionary: nil
                    )
                )
                annotations.append(ann)
            }
        }

        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    // Vocab dictionary lookups (demo mode only)
    if demoMode {
        for candidate in vocabs {
            guard seenTerms.insert(candidate.phrase.lowercased()).inserted else { continue }
            if let def = await fetchDefinition(candidate.phrase) {
                if let spanInfo = findSpan(of: candidate.phrase, in: text, after: text.startIndex) {
                    let ann = DemoAnnotation(
                        id: "v|\(candidate.phrase.lowercased())",
                        kind: "vocab",
                        surface: candidate.phrase,
                        span: DemoAnnotation.Span(start: spanInfo.start, end: spanInfo.end),
                        confidence: 0.79,
                        payload: DemoAnnotation.Payload(
                            summary: nil,
                            wikiTitle: nil,
                            dictionary: DemoAnnotation.DictPayload(
                                definition: def,
                                headword: candidate.phrase.lowercased()
                            )
                        )
                    )
                    annotations.append(ann)
                    log("  📖 \(candidate.phrase)")
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    if demoMode {
        let outputBase = demoOutputDir ?? "/Users/josephruocco/summa_site/demos"
        let demoDir = "\(outputBase)/\(book.slug)"
        try? FileManager.default.createDirectory(atPath: demoDir, withIntermediateDirectories: true)

        // Write chapter.html using the Gutenberg HTML content directly
        let html = chapterHTML(title: book.chapterTitle, innerHTML: source.chapterHTML)
        try? html.write(toFile: "\(demoDir)/chapter.html", atomically: true, encoding: .utf8)

        // Write catalog.json
        let catalog = DemoCatalog(
            schema_version: "1.2",
            source: DemoCatalog.Source(
                title: book.chapterTitle,
                createdAtISO8601: ISO8601DateFormatter().string(from: Date()),
                textLength: text.count,
                generator: "GutenbergTest/gutenberg-test"
            ),
            annotations: annotations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(catalog) {
            try? data.write(to: URL(fileURLWithPath: "\(demoDir)/catalog.json"))
        }

        log("  → Wrote \(demoDir)/")
    }

    allBookStats.append(bookStats)
    log("")
}

// MARK: - Write scores.log

let totalOk         = allBookStats.reduce(0) { $0 + $1.ok }
let totalNotFound   = allBookStats.reduce(0) { $0 + $1.notFound }
let totalSuppressed = allBookStats.reduce(0) { $0 + $1.suppressed }
let totalAll        = totalOk + totalNotFound + totalSuppressed
let totalScoreSum   = allBookStats.reduce(0.0) { $0 + $1.scoreSum }
let totalScoreCount = allBookStats.reduce(0) { $0 + $1.scoreCount }
let overallOkPct    = totalAll > 0 ? Double(totalOk) / Double(totalAll) * 100 : 0
let overallAvgScore = totalScoreCount > 0 ? totalScoreSum / Double(totalScoreCount) : 0

let timestamp = ISO8601DateFormatter().string(from: Date())
var logLines: [String] = []
logLines.append("=== \(timestamp)  ok=\(totalOk)/\(totalAll) (\(String(format:"%.0f", overallOkPct))%)  nf=\(totalNotFound)  sup=\(totalSuppressed)  avgScore=\(String(format:"%.3f", overallAvgScore)) ===")
for s in allBookStats {
    let pct = String(format: "%.0f", s.okPct)
    let avg = String(format: "%.3f", s.avgScore)
    logLines.append("  \(s.slug.padding(toLength: 20, withPad: " ", startingAt: 0))  ok=\(s.ok)/\(s.total) (\(pct)%)  nf=\(s.notFound)  sup=\(s.suppressed)  avgScore=\(avg)")
}
logLines.append("")

let logPath = "\(demoOutputDir)/scores.log"
let existing = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
try? (existing + logLines.joined(separator: "\n")).write(toFile: logPath, atomically: true, encoding: .utf8)
log("Scores appended to \(logPath)")

log("Done.")
