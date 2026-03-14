import Foundation
import CoreGraphics

actor CatalogRecorder {
    struct Catalog: Codable {
        var createdAtISO8601: String
        var sourceWindowTitle: String?
        var items: [Item]
    }

    struct DemoCatalog: Codable {
        struct Source: Codable {
            var title: String?
            var createdAtISO8601: String
            var textLength: Int
        }

        struct Annotation: Codable {
            struct Span: Codable {
                var start: Int
                var end: Int
            }

            struct Payload: Codable {
                struct DictionaryPayload: Codable {
                    var headword: String
                    var pos: String?
                    var definition: String
                }

                var dictionary: DictionaryPayload?
                var summary: String?
                var wikiTitle: String?
                var wikiURL: String?
            }

            var id: String
            var kind: String
            var surface: String
            var span: Span
            var confidence: Double
            var payload: Payload
        }

        var schema_version: String
        var source: Source
        var text: String
        var annotations: [Annotation]
    }

    struct Item: Codable, Hashable, Identifiable {
        enum Kind: String, Codable { case vocab, reference }

        var id: String
        var kind: Kind
        var text: String
        var rect: NormRect
        var contextBefore: String
        var contextAfter: String
        var contextWindow: Int
        var definition: String?
        var wikiSummary: String?
        var seenCount: Int
        var firstSeenISO8601: String
        var lastSeenISO8601: String
    }

    struct NormRect: Codable, Hashable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    private var itemsByID: [String: Item] = [:]
    private var sourceWindowTitle: String? = nil
    private var lastTokenStrings: [String] = []
    var contextWindow: Int = 6
    var rectQuant: Double = 0.005

    init(contextWindow: Int = 6, rectQuant: Double = 0.005) {
        self.contextWindow = contextWindow
        self.rectQuant = rectQuant
    }

    func setSourceWindowTitle(_ title: String?) {
        self.sourceWindowTitle = title
    }

    func reset() {
        itemsByID.removeAll()
        sourceWindowTitle = nil
        lastTokenStrings = []
    }

    func ingest(vocab: [HighlightBox], refs: [HighlightBox], tokens: [OCRToken], overlaySize: CGSize) async {
        guard overlaySize.width > 0, overlaySize.height > 0 else { return }
        guard !tokens.isEmpty else { return }

        let tokenRects: [CGRect] = tokens.map {
            Geometry.visionNormToOverlayTopLeft($0.rectNorm, overlaySize: overlaySize)
        }
        let tokenStrings: [String] = tokens.map { $0.text }
        lastTokenStrings = tokenStrings

        for h in (vocab + refs) {
            await ingestOne(highlight: h, tokenRects: tokenRects, tokenStrings: tokenStrings, overlaySize: overlaySize)
        }
    }

    private func ingestOne(highlight h: HighlightBox, tokenRects: [CGRect], tokenStrings: [String], overlaySize: CGSize) async {
        let now = iso8601Now()
        let nrect = normRectQuantized(h.rect, overlaySize: overlaySize)
        let id = makeID(kind: h.kind, text: h.text, rect: nrect)
        let idx = nearestTokenIndex(to: h.rect, tokenRects: tokenRects)
        let (before, after) = contextAround(index: idx, stream: tokenStrings, window: contextWindow)
        let kind: Item.Kind = (h.kind == .vocab) ? .vocab : .reference

        if var existing = itemsByID[id] {
            existing.seenCount += 1
            existing.lastSeenISO8601 = now
            if !before.isEmpty || !after.isEmpty {
                existing.contextBefore = before
                existing.contextAfter = after
                existing.contextWindow = contextWindow
            }
            if existing.definition == nil && kind == .vocab {
                existing.definition = Lookups.definition(for: h.text)
            }
            if existing.wikiSummary == nil && kind == .reference {
                let wiki = await Wikipedia.lookup(h.text, contextBefore: before, contextAfter: after)
                existing.wikiSummary = wiki.extract
            }
            itemsByID[id] = existing
        } else {
            var definition: String? = nil
            var wikiSummary: String? = nil

            if kind == .vocab {
                definition = Lookups.definition(for: h.text)
            } else {
                let wiki = await Wikipedia.lookup(h.text, contextBefore: before, contextAfter: after)
                wikiSummary = wiki.extract
            }

            itemsByID[id] = Item(
                id: id,
                kind: kind,
                text: h.text,
                rect: nrect,
                contextBefore: before,
                contextAfter: after,
                contextWindow: contextWindow,
                definition: definition,
                wikiSummary: wikiSummary,
                seenCount: 1,
                firstSeenISO8601: now,
                lastSeenISO8601: now
            )
        }
    }

    func snapshotCatalog() -> Catalog {
        Catalog(
            createdAtISO8601: iso8601Now(),
            sourceWindowTitle: sourceWindowTitle,
            items: itemsByID.values.sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.text.lowercased() < $1.text.lowercased()
            }
        )
    }

    func exportJSON(pretty: Bool = true) throws -> Data {
        let cat = snapshotCatalog()
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        return try enc.encode(cat)
    }

    func exportDemoJSON(pretty: Bool = true) throws -> Data {
        let demo = buildDemoCatalog()
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        return try enc.encode(demo)
    }

    private func buildDemoCatalog() -> DemoCatalog {
        let text = reconstructedText()
        let lowered = text.lowercased()
        var consumedRanges: [Range<String.Index>] = []
        var annotations: [DemoCatalog.Annotation] = []

        let sortedItems = itemsByID.values.sorted {
            if $0.seenCount != $1.seenCount { return $0.seenCount > $1.seenCount }
            return $0.text.count > $1.text.count
        }

        for item in sortedItems {
            guard let range = findRange(for: item.text, in: text, lowered: lowered, avoiding: consumedRanges) else { continue }
            consumedRanges.append(range)

            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            let payload: DemoCatalog.Annotation.Payload

            switch item.kind {
            case .vocab:
                let def = item.definition ?? "No dictionary entry found."
                payload = .init(
                    dictionary: .init(headword: item.text, pos: nil, definition: def),
                    summary: nil,
                    wikiTitle: nil,
                    wikiURL: nil
                )
            case .reference:
                payload = .init(
                    dictionary: nil,
                    summary: item.wikiSummary ?? "No Wikipedia summary found.",
                    wikiTitle: item.text,
                    wikiURL: nil
                )
            }

            annotations.append(
                .init(
                    id: item.id,
                    kind: item.kind.rawValue,
                    surface: item.text,
                    span: .init(start: start, end: end),
                    confidence: min(0.99, 0.55 + Double(item.seenCount) * 0.08),
                    payload: payload
                )
            )
        }

        annotations.sort { $0.span.start < $1.span.start }

        return DemoCatalog(
            schema_version: "1.1",
            source: .init(
                title: sourceWindowTitle,
                createdAtISO8601: iso8601Now(),
                textLength: text.count
            ),
            text: text,
            annotations: annotations
        )
    }

    private func reconstructedText() -> String {
        lastTokenStrings
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func findRange(
        for surface: String,
        in text: String,
        lowered: String,
        avoiding consumedRanges: [Range<String.Index>]
    ) -> Range<String.Index>? {
        let needle = surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }

        var searchStart = lowered.startIndex
        while searchStart < lowered.endIndex,
              let range = lowered.range(of: needle, range: searchStart..<lowered.endIndex) {
            if consumedRanges.allSatisfy({ !rangesOverlap($0, range) }) {
                return range
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private func rangesOverlap(_ a: Range<String.Index>, _ b: Range<String.Index>) -> Bool {
        a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
    }

    private func nearestTokenIndex(to highlightRect: CGRect, tokenRects: [CGRect]) -> Int {
        if tokenRects.isEmpty { return -1 }
        let target = CGPoint(x: highlightRect.midX, y: highlightRect.midY)
        var bestIndex = 0
        var bestDist = Double.greatestFiniteMagnitude

        for (i, r) in tokenRects.enumerated() {
            let c = CGPoint(x: r.midX, y: r.midY)
            let dx = Double(c.x - target.x)
            let dy = Double(c.y - target.y)
            let d = dx * dx + dy * dy
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
        }
        return bestIndex
    }

    private func contextAround(index: Int, stream: [String], window: Int) -> (before: String, after: String) {
        guard !stream.isEmpty, window > 0 else { return ("", "") }
        guard index >= 0, index < stream.count else { return ("", "") }

        let lo = max(0, index - window)
        let hi = min(stream.count - 1, index + window)
        let beforeSlice = (lo < index) ? stream[lo..<index] : []
        let afterSlice = (index < hi) ? stream[(index + 1)...hi] : []
        return (beforeSlice.joined(separator: " "), afterSlice.joined(separator: " "))
    }

    private func normRectQuantized(_ r: CGRect, overlaySize: CGSize) -> NormRect {
        let x = Double(r.minX / overlaySize.width)
        let y = Double(r.minY / overlaySize.height)
        let w = Double(r.width / overlaySize.width)
        let h = Double(r.height / overlaySize.height)

        func q(_ v: Double) -> Double {
            guard rectQuant > 0 else { return v }
            return (v / rectQuant).rounded() * rectQuant
        }

        return NormRect(x: q(x), y: q(y), w: q(w), h: q(h))
    }

    private func makeID(kind: HighlightBox.Kind, text: String, rect: NormRect) -> String {
        let k = (kind == .vocab) ? "v" : "r"
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(k)|\(t)|\(rect.x),\(rect.y),\(rect.w),\(rect.h)"
    }

    private func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
