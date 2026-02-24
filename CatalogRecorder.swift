import Foundation
import CoreGraphics

/// Records highlights across an entire session so you can export a static catalog.
/// Thread-safe by design (actor). No MainActor isolation issues.
actor CatalogRecorder {

    // MARK: - Public export model

    struct Catalog: Codable {
        var createdAtISO8601: String
        var sourceWindowTitle: String?
        var items: [Item]
    }

    struct Item: Codable, Hashable, Identifiable {
        enum Kind: String, Codable { case vocab, reference }

        var id: String                      // stable key
        var kind: Kind
        var text: String

        // Where it appeared (overlay-normalized 0..1)
        var rect: NormRect

        // Context captured at time of first/most recent sighting
        var contextBefore: String
        var contextAfter: String
        var contextWindow: Int

        // Optional payload (you can extend later)
        var definition: String?
        var wikiSummary: String?

        // Counts + last-seen
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

    // MARK: - Private state

    private var itemsByID: [String: Item] = [:]
    private var sourceWindowTitle: String? = nil

    /// Controls how much context to save around the matched token index.
    var contextWindow: Int = 6

    /// Dedup jitter control: how aggressively to bucket rects.
    /// 0.005 ≈ half a percent of width/height.
    var rectQuant: Double = 0.005

    // MARK: - Lifecycle

    init(contextWindow: Int = 6, rectQuant: Double = 0.005) {
        self.contextWindow = contextWindow
        self.rectQuant = rectQuant
    }

    func setSourceWindowTitle(_ title: String?) {
        self.sourceWindowTitle = title
    }

    func reset() {
        itemsByID.removeAll()
    }

    // MARK: - Ingest

    /// Call this once per processed frame AFTER you compute highlights.
    /// - Parameters:
    ///   - vocab/refs: highlight boxes from your HighlightEngine
    ///   - tokens: OCR tokens from this frame (Vision normalized rects + text)
    ///   - overlaySize: overlay size in points for this frame
    func ingest(
        vocab: [HighlightBox],
        refs: [HighlightBox],
        tokens: [OCRToken],
        overlaySize: CGSize
    ) {
        guard overlaySize.width > 0, overlaySize.height > 0 else { return }
        if tokens.isEmpty { return }

        // Prepare token geometry in overlay coords (top-left origin)
        let tokenRects: [CGRect] = tokens.map {
            Geometry.visionNormToOverlayTopLeft($0.rectNorm, overlaySize: overlaySize)
        }
        let tokenStrings: [String] = tokens.map { $0.text }

        // Ingest each highlight
        for h in (vocab + refs) {
            ingestOne(
                highlight: h,
                tokenRects: tokenRects,
                tokenStrings: tokenStrings,
                overlaySize: overlaySize
            )
        }
    }

    private func ingestOne(
        highlight h: HighlightBox,
        tokenRects: [CGRect],
        tokenStrings: [String],
        overlaySize: CGSize
    ) {
        let now = iso8601Now()

        // Stable-ish ID: kind + lowercased text + quantized normalized rect
        let nrect = normRectQuantized(h.rect, overlaySize: overlaySize)
        let id = makeID(kind: h.kind, text: h.text, rect: nrect)

        // Compute context via nearest token index (geometry-based; avoids duplicates-by-text issues)
        let idx = nearestTokenIndex(to: h.rect, tokenRects: tokenRects)
        let (before, after) = contextAround(index: idx, stream: tokenStrings, window: contextWindow)

        let kind: Item.Kind = (h.kind == .vocab) ? .vocab : .reference

        if var existing = itemsByID[id] {
            existing.seenCount += 1
            existing.lastSeenISO8601 = now

            // Update context if we have a better one (non-empty)
            if !before.isEmpty || !after.isEmpty {
                existing.contextBefore = before
                existing.contextAfter = after
                existing.contextWindow = contextWindow
            }

            itemsByID[id] = existing
        } else {
            let item = Item(
                id: id,
                kind: kind,
                text: h.text,
                rect: nrect,
                contextBefore: before,
                contextAfter: after,
                contextWindow: contextWindow,
                definition: nil,
                wikiSummary: nil,
                seenCount: 1,
                firstSeenISO8601: now,
                lastSeenISO8601: now
            )
            itemsByID[id] = item
        }
    }

    // MARK: - Export

    func snapshotCatalog() -> Catalog {
        let now = iso8601Now()
        let items = itemsByID.values
            .sorted { (a, b) in
                if a.kind != b.kind { return a.kind.rawValue < b.kind.rawValue }
                return a.text.lowercased() < b.text.lowercased()
            }

        return Catalog(
            createdAtISO8601: now,
            sourceWindowTitle: sourceWindowTitle,
            items: items
        )
    }

    func exportJSON(pretty: Bool = true) throws -> Data {
        let cat = snapshotCatalog()
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : []
        return try enc.encode(cat)
    }

    func exportJSONToFile(pretty: Bool = true, fileName: String? = nil) throws -> URL {
        let data = try exportJSON(pretty: pretty)

        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let name = fileName ?? "summa_catalog_\(Int(Date().timeIntervalSince1970)).json"
        let url = base.appendingPathComponent(name)

        try data.write(to: url, options: [.atomic])
        return url
    }

    // MARK: - Geometry helpers

    private func nearestTokenIndex(to highlightRect: CGRect, tokenRects: [CGRect]) -> Int {
        if tokenRects.isEmpty { return -1 }
        let target = CGPoint(x: highlightRect.midX, y: highlightRect.midY)

        var bestIndex = 0
        var bestDist = Double.greatestFiniteMagnitude

        for (i, r) in tokenRects.enumerated() {
            let c = CGPoint(x: r.midX, y: r.midY)
            let dx = Double(c.x - target.x)
            let dy = Double(c.y - target.y)
            let d = dx*dx + dy*dy
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
        }
        return bestIndex
    }

    /// Safe, never-crashing context slice.
    private func contextAround(index: Int, stream: [String], window: Int) -> (before: String, after: String) {
        guard !stream.isEmpty, window > 0 else { return ("", "") }
        guard index >= 0, index < stream.count else { return ("", "") }

        let lo = max(0, index - window)
        let hi = min(stream.count - 1, index + window)

        // before excludes the indexed token; after excludes too
        let beforeSlice = (lo < index) ? stream[lo..<index] : []
        let afterSlice  = (index < hi) ? stream[(index+1)...hi] : []

        return (beforeSlice.joined(separator: " "), afterSlice.joined(separator: " "))
    }

    private func normRectQuantized(_ r: CGRect, overlaySize: CGSize) -> NormRect {
        let x = Double(r.minX / overlaySize.width)
        let y = Double(r.minY / overlaySize.height)
        let w = Double(r.width  / overlaySize.width)
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
        // Include rect bucket to prevent same word in different places collapsing.
        return "\(k)|\(t)|\(rect.x),\(rect.y),\(rect.w),\(rect.h)"
    }

    // MARK: - Time

    private func iso8601Now() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
