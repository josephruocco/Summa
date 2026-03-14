import Foundation
import ScreenCaptureKit
import AppKit
import Combine

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
            if startIfNeeded {
                sessionOn = false
            }
            return
        }

        guard let win = windows.first(where: { $0.windowID == frontmostID }) else {
            currentWindowLabel = ""
            status = "Frontmost window wasn’t available to ScreenCaptureKit yet."
            if startIfNeeded {
                sessionOn = false
            }
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
        overlay?.clear()
        currentCapturedWindowID = nil
        sessionOn = false
        status = "Stopped."
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

        guard engine.changeGate.shouldProcess(image: frame.cgImage) else { return }

        status = "Scanning \(currentWindowLabel.isEmpty ? "window" : currentWindowLabel)…"
        let tokens = await OCR.ocrTokens(from: frame.cgImage)

        let result = engine.computeHighlights(
            tokens: tokens,
            windowSize: overlay?.currentSize ?? frame.size,
            showVocab: showVocab,
            showRefs: showRefs
        )

        lastHighlightCounts = (result.vocab.count, result.refs.count)
        overlay?.setHighlights(vocab: result.vocab, refs: result.refs)

        status = "Session running on \(currentWindowLabel)."
    }
}
