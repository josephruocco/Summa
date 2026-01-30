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
        overlay?.clear()
        status = "Stopped."
    }

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

        lastHighlightCounts = (result.vocab.count, result.refs.count)
        overlay?.setHighlights(vocab: result.vocab, refs: result.refs)

        status = "Session running. (Hover highlights for info.)"
    }
}
