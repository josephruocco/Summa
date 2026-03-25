import Foundation

// MARK: - Common words loader (standalone, no Bundle.main)

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

func fetchGutenbergText(bookID: Int) async throws -> String {
    // Try the plain-text UTF-8 URL first, then the older format
    let urls = [
        "https://www.gutenberg.org/files/\(bookID)/\(bookID)-0.txt",
        "https://www.gutenberg.org/files/\(bookID)/\(bookID).txt",
        "https://www.gutenberg.org/cache/epub/\(bookID)/pg\(bookID).txt"
    ]
    var lastError: Error?
    for urlString in urls {
        guard let url = URL(string: urlString) else { continue }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue("GutenbergTest/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { continue }
            if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
                return text
            }
        } catch {
            lastError = error
        }
    }
    throw lastError ?? URLError(.resourceUnavailable)
}

// Strip Gutenberg header/footer boilerplate so we analyse only the actual book text.
func stripBoilerplate(_ text: String) -> String {
    let startMarkers = ["*** START OF THE PROJECT GUTENBERG", "*** START OF THIS PROJECT GUTENBERG"]
    let endMarkers   = ["*** END OF THE PROJECT GUTENBERG",   "*** END OF THIS PROJECT GUTENBERG"]
    var body = text

    for marker in startMarkers {
        if let range = body.range(of: marker, options: .caseInsensitive) {
            if let nl = body[range.upperBound...].firstIndex(of: "\n") {
                body = String(body[body.index(after: nl)...])
            }
            break
        }
    }
    for marker in endMarkers {
        if let range = body.range(of: marker, options: .caseInsensitive) {
            body = String(body[..<range.lowerBound])
            break
        }
    }
    return body
}

// MARK: - Report

struct ReportRow {
    let bookID: Int
    let bookTitle: String
    let phrase: String
    let kind: String
    let status: String
    let wikiTitle: String
    let score: String
    let extract: String
    let debug: String
}

func tsvEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ")
     .replacingOccurrences(of: "\n", with: " ")
     .replacingOccurrences(of: "\r", with: "")
}

// MARK: - Main

let knownBooks: [(id: Int, title: String)] = [
    (2,    "The United States Declaration of Independence"),
    (174,  "The Picture of Dorian Gray"),
    (1342, "Pride and Prejudice"),
    (2701, "Moby Dick"),
    (4300, "Ulysses"),
    (5200, "Metamorphosis"),
    (11,   "Alice's Adventures in Wonderland"),
    (1661, "The Adventures of Sherlock Holmes"),
    (1400, "Great Expectations"),
    (98,   "A Tale of Two Cities"),
]

// Accept book IDs as arguments, or use the defaults above
let args = CommandLine.arguments.dropFirst()
let bookList: [(id: Int, title: String)]
if args.isEmpty {
    bookList = knownBooks
} else {
    bookList = args.compactMap { Int($0) }.map { id in
        (id, knownBooks.first(where: { $0.id == id })?.title ?? "Book \(id)")
    }
}

let maxRefsPerBook  = 60
let maxVocabPerBook = 40

// Progress and report output go to different streams
func log(_ msg: String) { fputs(msg + "\n", stderr) }

var rows: [ReportRow] = []
let commonWords = CommonWordsLoader.set

print(["bookID","bookTitle","phrase","kind","status","wikiTitle","score","extract","debug"]
    .joined(separator: "\t"))

for book in bookList {
    log("── Book \(book.id): \(book.title)")
    let rawText: String
    do {
        rawText = try await fetchGutenbergText(bookID: book.id)
    } catch {
        log("  ✗ Download failed: \(error.localizedDescription)")
        continue
    }
    let text = stripBoilerplate(rawText)
    log("  \(text.split(separator: " ").count) words after stripping boilerplate")

    let tokens = Tokenizer.tokenize(text)
    var candidates = Tokenizer.extractCandidates(from: tokens, commonWords: commonWords)

    // Cap per book to avoid hammering Wikipedia API
    let refs   = candidates.filter { $0.kind == .reference }.prefix(maxRefsPerBook)
    let vocabs = candidates.filter { $0.kind == .vocab      }.prefix(maxVocabPerBook)
    candidates = Array(refs) + Array(vocabs)

    log("  \(refs.count) ref candidates, \(vocabs.count) vocab candidates → \(candidates.count) lookups")

    for candidate in candidates {
        let result: WikiResult
        if candidate.kind == .reference {
            result = await Wikipedia.lookup(
                candidate.phrase,
                contextBefore: candidate.contextBefore.isEmpty ? nil : candidate.contextBefore,
                contextAfter:  candidate.contextAfter.isEmpty  ? nil : candidate.contextAfter
            )
        } else {
            // Vocab: just a dictionary definition, no Wikipedia lookup needed here —
            // mark as notFound so the report shows these as vocab-only terms.
            result = WikiResult(
                status: .notFound,
                requested: candidate.phrase,
                title: nil,
                extract: "(vocab — no lookup)",
                pageURL: nil,
                thumbnailURL: nil,
                debug: nil,
                score: nil
            )
        }

        let row = ReportRow(
            bookID:    book.id,
            bookTitle: book.title,
            phrase:    candidate.phrase,
            kind:      candidate.kind == .reference ? "ref" : "vocab",
            status:    result.status.rawValue,
            wikiTitle: result.title ?? "",
            score:     result.score.map { String(format: "%.2f", $0) } ?? "",
            extract:   String((result.extract ?? "").prefix(120)),
            debug:     result.debug ?? ""
        )

        print([
            String(row.bookID),
            tsvEscape(row.bookTitle),
            tsvEscape(row.phrase),
            row.kind,
            row.status,
            tsvEscape(row.wikiTitle),
            row.score,
            tsvEscape(row.extract),
            tsvEscape(row.debug)
        ].joined(separator: "\t"))

        let icon = result.status == .ok ? "✓" : (result.status == .suppressed ? "~" : "✗")
        log("  \(icon) \(candidate.phrase) → \(result.status.rawValue) \(result.title.map { "[\($0)]" } ?? "") \(result.score.map { String(format: "%.2f", $0) } ?? "")")

        // Gentle rate-limit to avoid hammering Wikipedia
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms between requests
    }

    log("")
}

log("Done. \(rows.count) total annotations.")
