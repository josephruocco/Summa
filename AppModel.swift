import Foundation
import ScreenCaptureKit
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var windows: [SCWindow] = []
    @Published var selectedWindowID: UInt32? = nil
    @Published var currentWindowLabel: String = ""

    @Published var sessionOn: Bool = false
    @Published var status: String = "Starting up…"
    @Published var showVocab: Bool = true
    @Published var showRefs: Bool = true

    @Published var lastHighlightCounts: (vocab: Int, ref: Int) = (0, 0)

    private let capture = CaptureSession()
    private let engine = HighlightEngine()
    private var overlay: OverlayController?
    private var startupAttempted = false
    private var currentCapturedWindowID: UInt32? = nil
    private var activationObserver: Any?

    private let recorder = CatalogRecorder()
    private var scrollMonitor: ScrollActivityMonitor?
    private var isScrolling = false
    private var lastVocab: [HighlightBox] = []
    private var lastRefs: [HighlightBox] = []

    private init() {
        NSApp.setActivationPolicy(.accessory)

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                await self.syncToFrontmostWindow(startIfNeeded: self.sessionOn)
            }
        }
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    func windowLabel(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "UnknownApp"
        let title = w.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = (title?.isEmpty == false) ? title! : "(untitled window)"
        return "\(app) — \(cleanTitle)"
    }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.windows = content.windows
                .filter { $0.isOnScreen }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            status = "Found \(windows.count) windows."
        } catch {
            status = "Failed to list windows: \(error.localizedDescription)"
        }
    }

    func startAutomaticModeIfNeeded() async {
        guard !startupAttempted else { return }
        startupAttempted = true
        await syncToFrontmostWindow(startIfNeeded: true)
    }

    func resumeAutomaticSession() async {
        await syncToFrontmostWindow(startIfNeeded: true)
    }

    func syncToFrontmostWindow(startIfNeeded: Bool) async {
        await refreshWindows()

        guard let frontmostID = WindowBounds.frontmostWindowID() else {
            currentWindowLabel = ""
            status = "No suitable frontmost window found."
            if startIfNeeded { sessionOn = false }
            return
        }

        guard let win = windows.first(where: { $0.windowID == frontmostID }) else {
            currentWindowLabel = ""
            status = "Frontmost window wasn’t available to ScreenCaptureKit yet."
            if startIfNeeded { sessionOn = false }
            return
        }

        selectedWindowID = frontmostID
        currentWindowLabel = windowLabel(win)

        if currentCapturedWindowID != frontmostID {
            status = "Targeting \(currentWindowLabel)."
        }

        if startIfNeeded {
            await startSession(for: win)
        }
    }

    func stopSession() {
        capture.stop()
        stopScrollMonitor()
        overlay?.clear()
        currentCapturedWindowID = nil
        sessionOn = false
        lastVocab = []
        lastRefs = []
        lastHighlightCounts = (0, 0)
        recorderReset()
        status = "Stopped."
    }

    func exportCatalog() async {
        do {
            let data = try await recorder.exportJSON(pretty: true)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "summa_catalog.json"
            panel.allowedContentTypes = [UTType.json]
            panel.canCreateDirectories = true

            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: [.atomic])
                status = "Exported: \(url.lastPathComponent)"
            } else {
                status = "Export cancelled."
            }
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func startSession(for win: SCWindow) async {
        let id = win.windowID

        if currentCapturedWindowID == id, sessionOn {
            status = "Session running on \(windowLabel(win))."
            return
        }

        capture.stop()
        overlay?.clear()

        if overlay == nil {
            overlay = OverlayController()
        }

        startScrollMonitor()
        await recorder.setSourceWindowTitle(windowLabel(win))

        status = "Starting capture for \(windowLabel(win))…"

        do {
            try await capture.startCapturing(window: win) { [weak self] frame in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleFrame(frame, windowID: id)
                }
            }
            currentCapturedWindowID = id
            selectedWindowID = id
            currentWindowLabel = windowLabel(win)
            sessionOn = true
            status = "Session running on \(currentWindowLabel)."
        } catch {
            currentCapturedWindowID = nil
            sessionOn = false
            status = "Capture failed: \(error.localizedDescription)"
        }
    }

    private func handleFrame(_ frame: CapturedFrame, windowID: UInt32) async {
        if let bounds = WindowBounds.boundsForWindow(windowID: windowID) {
            overlay?.setOverlayFrame(bounds)
        }

        if isScrolling { return }
        guard engine.changeGate.shouldProcess(image: frame.cgImage) else { return }

        status = "Scanning \(currentWindowLabel.isEmpty ? "window" : currentWindowLabel)…"
        let tokens = await OCR.ocrTokens(from: frame.cgImage)

        let result = engine.computeHighlights(
            tokens: tokens,
            windowSize: overlay?.currentSize ?? frame.size,
            showVocab: showVocab,
            showRefs: showRefs
        )

        lastVocab = result.vocab
        lastRefs = result.refs
        lastHighlightCounts = (result.vocab.count, result.refs.count)
        overlay?.setHighlights(vocab: result.vocab, refs: result.refs)

        Task {
            await self.recorder.ingest(
                vocab: result.vocab,
                refs: result.refs,
                tokens: tokens,
                overlaySize: self.overlay?.currentSize ?? frame.size
            )
        }

        status = "Session running on \(currentWindowLabel)."
    }

    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }

        scrollMonitor = ScrollActivityMonitor(quietPeriod: 0.18) { [weak self] active in
            guard let self else { return }
            Task { @MainActor in
                self.isScrolling = active
                if active {
                    self.overlay?.clear()
                    self.status = "Scrolling…"
                } else {
                    self.overlay?.setHighlights(vocab: self.lastVocab, refs: self.lastRefs)
                    self.status = self.sessionOn ? "Session running on \(self.currentWindowLabel)." : "Paused"
                }
            }
        }
        scrollMonitor?.start()
    }

    private func stopScrollMonitor() {
        scrollMonitor?.stop()
        scrollMonitor = nil
        isScrolling = false
    }

    private func recorderReset() {
        Task { await recorder.reset() }
    }
}

final class ScrollActivityMonitor {
    private var monitor: Any?
    private var endWorkItem: DispatchWorkItem?
    private let quietPeriod: TimeInterval
    private let onScrollActiveChanged: (Bool) -> Void

    private(set) var isScrolling: Bool = false {
        didSet {
            guard isScrolling != oldValue else { return }
            onScrollActiveChanged(isScrolling)
        }
    }

    init(quietPeriod: TimeInterval = 0.18, onScrollActiveChanged: @escaping (Bool) -> Void) {
        self.quietPeriod = quietPeriod
        self.onScrollActiveChanged = onScrollActiveChanged
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            self?.handleScrollEvent()
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        endWorkItem?.cancel()
        endWorkItem = nil
        isScrolling = false
    }

    private func handleScrollEvent() {
        if !isScrolling { isScrolling = true }
        endWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.isScrolling = false
        }
        endWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + quietPeriod, execute: work)
    }
}

actor CatalogRecorder {
    struct Catalog: Codable {
        var createdAtISO8601: String
        var sourceWindowTitle: String?
        var items: [Item]
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
    }

    func ingest(vocab: [HighlightBox], refs: [HighlightBox], tokens: [OCRToken], overlaySize: CGSize) {
        guard overlaySize.width > 0, overlaySize.height > 0 else { return }
        guard !tokens.isEmpty else { return }

        let tokenRects: [CGRect] = tokens.map {
            OCR.normToRectInOverlay_TopLeftOrigin($0.rectNorm, overlaySize: overlaySize)
        }
        let tokenStrings: [String] = tokens.map { $0.text }

        for h in (vocab + refs) {
            ingestOne(highlight: h, tokenRects: tokenRects, tokenStrings: tokenStrings, overlaySize: overlaySize)
        }
    }

    private func ingestOne(highlight h: HighlightBox, tokenRects: [CGRect], tokenStrings: [String], overlaySize: CGSize) {
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
            itemsByID[id] = existing
        } else {
            itemsByID[id] = Item(
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
