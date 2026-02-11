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

    // True while the user is actively scrolling (debounced)
    @Published var highlightsSuppressed: Bool = false

    private let capture = CaptureSession()
    private let engine = HighlightEngine()
    private var overlay: OverlayController?

    // Scroll suppression
    private var scrollMonitor: ScrollActivityMonitor?

    // Cache last computed highlights so we can restore instantly after scroll ends
    private var cachedVocab: [HighlightBox] = []
    private var cachedRefs: [HighlightBox] = []

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

        // Create overlay if needed
        if overlay == nil {
            overlay = OverlayController()
        }

        // Start scroll suppression once per session
        startScrollSuppressionIfNeeded()

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
        stopScrollSuppression()

        cachedVocab = []
        cachedRefs = []
        highlightsSuppressed = false

        overlay?.clear()
        status = "Stopped."
    }

    // MARK: - Scroll suppression

    private func startScrollSuppressionIfNeeded() {
        guard scrollMonitor == nil else { return }

        scrollMonitor = ScrollActivityMonitor(quietPeriod: 0.20) { [weak self] isScrolling in
            guard let self else { return }
            Task { @MainActor in
                self.highlightsSuppressed = isScrolling

                if isScrolling {
                    // Hide everything immediately while scrolling
                    // (also cancels any in-flight tooltip tasks via clear())
                    self.overlay?.clear()
                } else {
                    // Restore last-known highlights instantly after scrolling stops
                    self.overlay?.setHighlights(
                        vocab: self.showVocab ? self.cachedVocab : [],
                        refs:  self.showRefs  ? self.cachedRefs  : []
                    )
                }
            }
        }

        scrollMonitor?.start()
    }

    private func stopScrollSuppression() {
        scrollMonitor?.stop()
        scrollMonitor = nil
    }

    // MARK: - Frame handling

    private func handleFrame(_ frame: CapturedFrame, windowID: UInt32) async {
        // Update overlay frame to track window bounds
        if let bounds = WindowBounds.boundsForWindow(windowID: windowID) {
            overlay?.setOverlayFrame(bounds)
        }

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

        // Cache latest highlights (for post-scroll restore)
        cachedVocab = result.vocab
        cachedRefs = result.refs
        lastHighlightCounts = (result.vocab.count, result.refs.count)

        // If user is scrolling, don't render now — we'll restore from cache on scroll end
        if highlightsSuppressed {
            status = "Session running. (Scrolling…)"
            return
        }

        overlay?.setHighlights(vocab: result.vocab, refs: result.refs)
        status = "Session running. (Hover highlights for info.)"
    }
}
