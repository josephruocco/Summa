import Foundation
import ScreenCaptureKit
import AppKit
import Combine
import CoreGraphics
import UniformTypeIdentifiers
import AuthenticationServices

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private static let exportFolderBookmarkKey = "summa.exportFolderBookmark"
    private static let overlayLayoutKey = "summa.overlayLayout"
    private static let annotationDebugKey = "summa.annotationDebug"
    private static let premiumKey = "summa.premiumAnnotations"

    @Published var windows: [SCWindow] = []
    @Published var selectedWindowID: UInt32? = nil
    @Published var currentWindowLabel: String = ""

    @Published var sessionOn: Bool = false
    @Published var windowLocked: Bool = false
    @Published var status: String = "Starting up…"
    @Published var showVocab: Bool = true
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
    @Published var premiumAnnotations: Bool = false {
        didSet {
            UserDefaults.standard.set(premiumAnnotations, forKey: Self.premiumKey)
            if !premiumAnnotations { overlay?.setPremiumHighlights([]) }
        }
    }
    // Premium annotation credentials, bound to settings fields and persisted
    // where ScreenAnnotator reads them. Testers set an access code (and, until
    // a default proxy URL is baked in, the proxy URL); the raw API key is a dev
    // fallback used only when no proxy is configured.
    @Published var accessCode: String = "" {
        didSet { UserDefaults.standard.set(accessCode, forKey: ScreenAnnotator.accessTokenDefaultsKey) }
    }
    @Published var proxyURL: String = "" {
        didSet { UserDefaults.standard.set(proxyURL, forKey: ScreenAnnotator.proxyURLDefaultsKey) }
    }
    @Published var anthropicAPIKey: String = "" {
        didSet { UserDefaults.standard.set(anthropicAPIKey, forKey: ScreenAnnotator.apiKeyDefaultsKey) }
    }
    // nil when not signed in with Apple; the email the proxy authorized otherwise.
    @Published var signedInEmail: String? = nil

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
    private var lastSidebarAnchorX: CGFloat = 0
    private var premiumTask: Task<Void, Never>?
    private var lastPremiumTextHash: Int?
    private var requestedScreenAccess = false
    private var screenAccessDenied = false

    private init() {
        NSApp.setActivationPolicy(.accessory)
        hasExportFolder = loadExportFolderURL() != nil
        overlayLayout = loadOverlayLayout()
        showAnnotationDebug = UserDefaults.standard.bool(forKey: Self.annotationDebugKey)
        premiumAnnotations = UserDefaults.standard.bool(forKey: Self.premiumKey)
        accessCode = UserDefaults.standard.string(forKey: ScreenAnnotator.accessTokenDefaultsKey) ?? ""
        proxyURL = UserDefaults.standard.string(forKey: ScreenAnnotator.proxyURLDefaultsKey) ?? ""
        anthropicAPIKey = UserDefaults.standard.string(forKey: ScreenAnnotator.apiKeyDefaultsKey) ?? ""
        signedInEmail = UserDefaults.standard.string(forKey: ScreenAnnotator.signedInEmailDefaultsKey)

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.windowLocked, let lockedID = self.currentCapturedWindowID {
                    // Layer the overlay between the pinned window and
                    // whatever the user just switched to, so highlights
                    // stay visible where they don't overlap.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    let frontID = WindowBounds.frontmostWindowID()
                    if frontID == lockedID {
                        self.overlay?.setOverlayFloating()
                    } else {
                        self.overlay?.setOverlayBehindFront(pinnedWindowID: lockedID)
                    }
                    return
                }
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

    private func requestScreenAccessOnce() {
        if !requestedScreenAccess {
            requestedScreenAccess = true
            _ = CGRequestScreenCaptureAccess()
        }
        if sessionOn { sessionOn = false }
        status = "Grant Summa access under System Settings ▸ Privacy & Security ▸ Screen Recording, then reopen Summa."
    }

    // Gate for every ScreenCaptureKit entry point, so a missing permission never
    // becomes a loop of prompts (that repeated re-request on each app activation
    // was the bug). CGPreflightScreenCaptureAccess alone isn't trustworthy: after
    // a permission reset / bundle-id change it can report a stale "granted",
    // letting the real capture call prompt anyway. So we ALSO latch on the
    // actual capture failure (screenAccessDenied) and stop trying until the app
    // is relaunched -- Screen Recording grants require a relaunch regardless.
    private func ensureScreenPermission() -> Bool {
        if screenAccessDenied {
            requestScreenAccessOnce()
            return false
        }
        if CGPreflightScreenCaptureAccess() { return true }
        requestScreenAccessOnce()
        return false
    }

    func refreshWindows() async {
        guard ensureScreenPermission() else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            self.windows = content.windows
                .filter { $0.isOnScreen }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            status = "Found \(windows.count) windows."
        } catch {
            // A throw here almost always means Screen Recording is denied even
            // if preflight lied. Latch it so we stop re-calling (and re-prompting)
            // until the app is relaunched.
            screenAccessDenied = true
            requestScreenAccessOnce()
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
        guard ensureScreenPermission() else { return }
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
        overlay?.windowLabel = currentWindowLabel

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
        premiumTask?.cancel()
        lastPremiumTextHash = nil
        overlay?.clear()
        currentCapturedWindowID = nil
        sessionOn = false
        windowLocked = false
        lastVocab = []
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

    // MARK: - Sign in with Apple

    // Called from the SignInWithAppleButton completion. On success we hand
    // Apple's identity token to the proxy, which verifies it, checks the
    // allowlist, and returns a Summa session token we store and reuse.
    func handleAppleAuthorization(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            status = "Sign in failed: \(error.localizedDescription)"
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                status = "Sign in returned no identity token."
                return
            }
            Task { await exchangeAppleToken(identityToken) }
        }
    }

    private func exchangeAppleToken(_ identityToken: String) async {
        guard let base = ScreenAnnotator.proxyURL() else {
            status = "Set the proxy URL before signing in."
            return
        }
        guard let (sessionToken, email) = await ScreenAnnotator.exchangeAppleToken(identityToken, proxyBase: base) else {
            status = "Sign in was rejected (is your email on the allowlist?)."
            return
        }
        UserDefaults.standard.set(sessionToken, forKey: ScreenAnnotator.sessionTokenDefaultsKey)
        UserDefaults.standard.set(email, forKey: ScreenAnnotator.signedInEmailDefaultsKey)
        signedInEmail = email
        status = "Signed in as \(email)."
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: ScreenAnnotator.sessionTokenDefaultsKey)
        UserDefaults.standard.removeObject(forKey: ScreenAnnotator.signedInEmailDefaultsKey)
        signedInEmail = nil
        status = "Signed out."
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
            overlay?.windowLabel = currentWindowLabel
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
        // References come exclusively from the premium AI annotator now; the
        // legacy keyword matcher (which produced junk like "Hanoverian" -> a dog
        // breed and "Lord" -> Lorde the singer) has been removed. This engine
        // only supplies vocab dictionary highlights.
        let vocab = enrichContexts(
            engine.computeHighlights(tokens: tokens, windowSize: overlaySize, showVocab: showVocab),
            tokens: tokens,
            overlaySize: overlaySize
        )
        let sidebarAnchorX = computeSidebarAnchorX(tokens: tokens, overlaySize: overlaySize)

        lastVocab = vocab
        lastSidebarAnchorX = sidebarAnchorX
        lastHighlightCounts = (vocab.count, 0)
        overlay?.setHighlights(vocab: vocab, sidebarAnchorX: sidebarAnchorX)
        overlay?.setOCRTokens(tokens, overlaySize: overlaySize)

        runPremiumAnnotationIfEnabled(tokens: tokens, overlaySize: overlaySize)

        Task {
            await self.recorder.ingest(
                vocab: vocab,
                refs: [],
                tokens: tokens,
                overlaySize: overlaySize
            )
        }

        status = "Session running on \(currentWindowLabel)."
    }

    // Kicks off a background premium-annotation pass for the current screen.
    // Cheap-gated: only when enabled and a key is present, and skipped when the
    // visible text is unchanged from the last pass so we don't re-map/re-render
    // (and don't re-bill) on cosmetic frame changes like a blinking cursor.
    // ScreenAnnotator caches LLM responses by screen text, so scrolling back to
    // an already-read screen is free.
    private func runPremiumAnnotationIfEnabled(tokens: [OCRToken], overlaySize: CGSize) {
        guard premiumAnnotations, ScreenAnnotator.isConfigured else { return }

        let textHash = tokens.map(\.text).joined(separator: " ").hashValue
        if textHash == lastPremiumTextHash { return }
        lastPremiumTextHash = textHash

        let ctx = currentWindowLabel.isEmpty ? nil : currentWindowLabel
        premiumTask?.cancel()
        overlay?.setPremiumLoading(true)
        premiumTask = Task { [weak self] in
            // Annotations stream in and render incrementally as the model
            // produces them; setPremiumHighlights also clears the loading pill.
            for await annotations in ScreenAnnotator.annotate(
                tokens: tokens, overlaySize: overlaySize, bookContext: ctx
            ) {
                if Task.isCancelled { break }
                self?.overlay?.setPremiumHighlights(annotations)
            }
        }
    }

    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }

        scrollMonitor = ScrollActivityMonitor(quietPeriod: 0.18) { [weak self] active in
            guard let self else { return }
            Task { @MainActor in
                self.isScrolling = active
                if active {
                    self.premiumTask?.cancel()
                    self.lastPremiumTextHash = nil
                    self.overlay?.clear()
                    self.status = "Scrolling…"
                } else {
                    self.overlay?.setHighlights(
                        vocab: self.lastVocab,
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
