import Foundation
import ScreenCaptureKit
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private static let exportFolderBookmarkKey = "summa.exportFolderBookmark"
    private static let overlayLayoutKey = "summa.overlayLayout"
    private static let annotationDebugKey = "summa.annotationDebug"

    @Published var windows: [SCWindow] = []
    @Published var selectedWindowID: UInt32? = nil
    @Published var currentWindowLabel: String = ""

    @Published var sessionOn: Bool = false
    @Published var status: String = "Starting up…"
    @Published var showVocab: Bool = true
    @Published var showRefs: Bool = true
    @Published var overlayLayout: OverlayAnnotationLayout = .hover {
        didSet {
            UserDefaults.standard.set(overlayLayout.rawValue, forKey: Self.overlayLayoutKey)
            overlay?.setLayoutMode(overlayLayout)
        }
    }
    @Published var showAnnotationDebug: Bool = false {
        didSet {
            UserDefaults.standard.set(showAnnotationDebug, forKey: Self.annotationDebugKey)
            overlay?.setDebugMode(showAnnotationDebug)
        }
    }

    @Published var lastHighlightCounts: (vocab: Int, ref: Int) = (0, 0)
    @Published var hasExportFolder: Bool = false

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
    private var lastSidebarAnchorX: CGFloat = 0

    private init() {
        NSApp.setActivationPolicy(.accessory)
        hasExportFolder = loadExportFolderURL() != nil
        overlayLayout = loadOverlayLayout()
        showAnnotationDebug = UserDefaults.standard.bool(forKey: Self.annotationDebugKey)

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
        Task { await recorder.reset() }
        status = "Stopped."
    }

    func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Export Folder"
        panel.message = "Pick a folder where SUMMA should save demo catalogs."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()

        guard response == .OK, let url = panel.url else {
            status = "Export folder selection cancelled."
            return
        }

        do {
            try saveExportFolder(url)
            hasExportFolder = true
            status = "Export folder set: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "Couldn’t save export folder: \(error.localizedDescription)"
        }
    }

    func exportCatalog() async {
        guard let folderURL = loadExportFolderURL() else {
            status = "Choose an export folder first."
            return
        }

        let accessStarted = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessStarted { folderURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try await recorder.exportDemoJSON(pretty: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = folderURL.appendingPathComponent("summa_demo_catalog_\(timestamp).json")

            try data.write(to: url, options: [.atomic])
            status = "Exported demo catalog: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
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
            overlay?.setLayoutMode(overlayLayout)
            overlay?.setDebugMode(showAnnotationDebug)
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
        let cropProfile = OCR.cropProfile(forWindowLabel: currentWindowLabel)
        let tokens = await OCR.ocrTokens(from: frame.cgImage, cropProfile: cropProfile)

        let overlaySize = overlay?.currentContentSize ?? frame.size
        let rawResult = engine.computeHighlights(
            tokens: tokens,
            windowSize: overlaySize,
            showVocab: showVocab,
            showRefs: showRefs
        )
        let result = (
            vocab: enrichContexts(rawResult.vocab, tokens: tokens, overlaySize: overlaySize),
            refs: enrichContexts(rawResult.refs, tokens: tokens, overlaySize: overlaySize)
        )
        let sidebarAnchorX = computeSidebarAnchorX(tokens: tokens, overlaySize: overlaySize)

        lastVocab = result.vocab
        lastRefs = result.refs
        lastSidebarAnchorX = sidebarAnchorX
        lastHighlightCounts = (result.vocab.count, result.refs.count)
        overlay?.setHighlights(vocab: result.vocab, refs: result.refs, sidebarAnchorX: sidebarAnchorX)

        Task {
            await self.recorder.ingest(
                vocab: result.vocab,
                refs: result.refs,
                tokens: tokens,
                overlaySize: overlaySize
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
                    self.overlay?.setHighlights(
                        vocab: self.lastVocab,
                        refs: self.lastRefs,
                        sidebarAnchorX: self.lastSidebarAnchorX
                    )
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

    private func saveExportFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmark, forKey: Self.exportFolderBookmarkKey)
    }

    private func loadExportFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.exportFolderBookmarkKey) else {
            return nil
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                try saveExportFolder(url)
            }

            return url
        } catch {
            return nil
        }
    }

    private func loadOverlayLayout() -> OverlayAnnotationLayout {
        guard let raw = UserDefaults.standard.string(forKey: Self.overlayLayoutKey),
              let layout = OverlayAnnotationLayout(rawValue: raw) else {
            return .hover
        }

        return layout
    }

    private func computeSidebarAnchorX(tokens: [OCRToken], overlaySize: CGSize) -> CGFloat {
        guard !tokens.isEmpty, overlaySize.width > 0 else { return 0 }

        let rightEdges = tokens
            .map { OCR.normToRectInOverlay_TopLeftOrigin($0.rectNorm, overlaySize: overlaySize).maxX }
            .filter { $0.isFinite && $0 > 0 && $0 < overlaySize.width - 8 }
            .sorted()

        guard !rightEdges.isEmpty else { return 0 }

        let percentileIndex = min(rightEdges.count - 1, max(0, Int(Double(rightEdges.count - 1) * 0.92)))
        return rightEdges[percentileIndex]
    }

    private func enrichContexts(_ highlights: [HighlightBox], tokens: [OCRToken], overlaySize: CGSize) -> [HighlightBox] {
        guard !highlights.isEmpty, !tokens.isEmpty else { return highlights }

        let tokenRects = tokens.map { OCR.normToRectInOverlay_TopLeftOrigin($0.rectNorm, overlaySize: overlaySize) }
        let tokenStrings = tokens.map(\.text)

        return highlights.map { highlight in
            let index = nearestTokenIndex(to: highlight.rect, tokenRects: tokenRects)
            let context = contextAround(index: index, stream: tokenStrings, window: 8)
            return HighlightBox(
                text: highlight.text,
                rect: highlight.rect,
                kind: highlight.kind,
                contextBefore: context.before,
                contextAfter: context.after
            )
        }
    }

    private func nearestTokenIndex(to highlightRect: CGRect, tokenRects: [CGRect]) -> Int {
        guard !tokenRects.isEmpty else { return -1 }

        let target = CGPoint(x: highlightRect.midX, y: highlightRect.midY)
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude

        for (index, rect) in tokenRects.enumerated() {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let dx = Double(center.x - target.x)
            let dy = Double(center.y - target.y)
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        return bestIndex
    }

    private func contextAround(index: Int, stream: [String], window: Int) -> (before: String, after: String) {
        guard !stream.isEmpty, window > 0, index >= 0, index < stream.count else { return ("", "") }

        let lowerBound = max(0, index - window)
        let upperBound = min(stream.count - 1, index + window)
        let before = lowerBound < index ? stream[lowerBound..<index].joined(separator: " ") : ""
        let after = index < upperBound ? stream[(index + 1)...upperBound].joined(separator: " ") : ""
        return (before, after)
    }
}
