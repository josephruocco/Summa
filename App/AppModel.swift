import Foundation
import ScreenCaptureKit
import AppKit
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var windows: [SCWindow] = []
    @Published var selectedWindowID: UInt32? = nil

    @Published var sessionOn: Bool = false
    @Published var status: String = "Idle"
    @Published var showVocab: Bool = true
    @Published var showRefs: Bool = true

    @Published var lastHighlightCounts: (vocab: Int, ref: Int) = (0, 0)

    private let capture = CaptureSession()
    private let engine = HighlightEngine()
    private var overlay: OverlayController?

    // Export/catalog
    private let recorder = CatalogRecorder()

    // Scroll gating
    private var scrollMonitor: ScrollActivityMonitor?
    private var isScrolling: Bool = false

    // Keep last highlights so we can restore after scroll ends (optional)
    private var lastVocab: [HighlightBox] = []
    private var lastRefs: [HighlightBox] = []

    func windowLabel(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "UnknownApp"
        let title = w.title ?? "(no title)"
        return "\(app) — \(title)"
    }

    func refreshWindows() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.windows = content.windows
                .filter { $0.isOnScreen }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            status = "Found \(windows.count) windows."
        } catch {
            status = "Failed to list windows: \(error)"
        }
    }

    func startSession() async {
        guard let id = selectedWindowID,
              let win = windows.first(where: { $0.windowID == id }) else {
            status = "Pick a target window first."
            sessionOn = false
            return
        }

        if overlay == nil { overlay = OverlayController() }

        startScrollMonitor()

        status = "Starting capture… (you may be prompted for Screen Recording permission)"
        do {
            try await capture.startCapturing(window: win) { [weak self] frame in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleFrame(frame, windowID: id)
                }
            }
            status = "Session running."
        } catch {
            status = "Capture failed: \(error)"
            sessionOn = false
        }
    }

    func stopSession() {
        capture.stop()
        stopScrollMonitor()

        overlay?.clear()
        lastVocab = []
        lastRefs = []
        lastHighlightCounts = (0, 0)

        status = "Stopped."
    }

    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }

        scrollMonitor = ScrollActivityMonitor(quietPeriod: 0.18) { [weak self] active in
            guard let self else { return }
            Task { @MainActor in
                self.isScrolling = active

                if active {
                    // Immediately hide while scrolling
                    self.overlay?.clear()
                    self.status = "Scrolling…"
                } else {
                    // Scrolling ended: show last highlights (next OCR will update anyway)
                    self.overlay?.setHighlights(vocab: self.lastVocab, refs: self.lastRefs)
                    self.status = "Session running."
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

    private func handleFrame(_ frame: CapturedFrame, windowID: UInt32) async {
        // Track window bounds
        if let bounds = WindowBounds.boundsForWindow(windowID: windowID) {
            overlay?.setOverlayFrame(bounds)
        }

        // HARD GATE: do nothing while scrolling (prevents re-applying highlights)
        if isScrolling { return }

        // Gate OCR on page-change
        guard engine.changeGate.shouldProcess(image: frame.cgImage) else { return }

        status = "OCR…"
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

        // Record session-wide catalog (actor)
        Task {
            await recorder.ingest(
                vocab: result.vocab,
                refs: result.refs,
                tokens: tokens,
                overlaySize: overlay?.currentSize ?? frame.size
            )
        }

        status = "Session running. (Hover highlights for info.)"
    }
    
    @MainActor
    func exportCatalog() async {
        do {
            let data = try await recorder.exportJSON(pretty: true)   // <- returns Data
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "summa_catalog.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true

            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: [.atomic])
                status = "Exported: \(url.lastPathComponent)"
            } else {
                status = "Export cancelled."
            }
        } catch {
            status = "Export failed: \(error)"
        }
    }
}
