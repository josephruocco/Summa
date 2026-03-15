import Foundation
import ScreenCaptureKit
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private static let exportFolderBookmarkKey = "summa.exportFolderBookmark"

    @Published var windows: [SCWindow] = []
    @Published var selectedWindowID: UInt32? = nil
    @Published var currentWindowLabel: String = ""

    @Published var sessionOn: Bool = false
    @Published var status: String = "Starting up…"
    @Published var showVocab: Bool = true
    @Published var showRefs: Bool = true

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

    private init() {
        NSApp.setActivationPolicy(.accessory)
        hasExportFolder = loadExportFolderURL() != nil

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
}
