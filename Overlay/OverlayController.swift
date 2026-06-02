import AppKit
import SwiftUI

enum OverlayAnnotationLayout: String, CaseIterable, Identifiable {
    case hover
    case side

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover: return "Hover"
        case .side: return "Side"
        }
    }
}

struct OverlaySidebarAnnotation: Identifiable, Equatable {
    let id: String
    let highlight: HighlightBox
    let tooltip: OverlayTooltip
}

@MainActor
final class OverlayController {
    private static let sideRailGutterWidth: CGFloat = 430
    private static let sideRailOuterPadding: CGFloat = 10

    private let window: NSPanel
    private let host: NSHostingView<OverlayView>

    private var vocab: [HighlightBox] = []
    private var refs: [HighlightBox] = []
    private var layoutMode: OverlayAnnotationLayout = .hover
    private var sideTooltips: [String: OverlayTooltip] = [:]
    private var sideLookupTasks: [String: Task<Void, Never>] = [:]
    private var suppressedLookupKeys = Set<String>()

    private var hoverTimer: Timer?
    private var hovered: HighlightBox?
    private var hoverTask: Task<Void, Never>?
    private var targetFrame: CGRect = .zero
    private var sidebarAnchorX: CGFloat = 0
    private var debugModeEnabled = false
    private var lastOCRTokenRects: [(text: String, rect: CGRect)] = []
    // Last rendered tooltip frame, reported via SwiftUI preference key. Used
    // for mouse hit-testing so we don't have to hardcode tooltip dimensions
    // (multi-option pickers have variable height).
    private var tooltipFrame: CGRect? = nil
    var windowLabel: String = ""

    var currentSize: CGSize { window.contentView?.bounds.size ?? .zero }
    var currentContentSize: CGSize { targetFrame.isEmpty ? currentSize : targetFrame.size }

    init() {
        let view = OverlayView(
            vocab: [],
            refs: [],
            hovered: nil,
            tooltip: nil,
            layoutMode: .hover,
            sideAnnotations: [],
            sideRailWidth: 0,
            sidebarAnchorX: 0,
            debugModeEnabled: false
        )
        host = NSHostingView(rootView: view)

        window = NSPanel(
            contentRect: CGRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        window.contentView = host
        window.orderFrontRegardless()

        startHoverPolling()
    }

    /// Place the overlay just above the pinned window so the frontmost
    /// window naturally covers it where they overlap.
    func setOverlayBehindFront(pinnedWindowID: UInt32) {
        hovered = nil
        hoverTask?.cancel()
        hoverTask = nil
        render(hovered: nil, tooltip: nil)
        window.level = .normal
        window.order(.above, relativeTo: Int(pinnedWindowID))
    }

    /// Restore the overlay to floating level (on top of everything).
    func setOverlayFloating() {
        window.level = .floating
        window.orderFrontRegardless()
    }

    func setOverlayFrame(_ frame: CGRect) {
        targetFrame = frame
        applyOverlayFrame()
    }

    func setOCRTokens(_ tokens: [OCRToken], overlaySize: CGSize) {
        lastOCRTokenRects = tokens.compactMap { token in
            let text = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2 else { return nil }
            let rect = OCR.normToRectInOverlay_TopLeftOrigin(token.rectNorm, overlaySize: overlaySize)
            return (text: text, rect: rect)
        }
    }

    func setHighlights(vocab: [HighlightBox], refs: [HighlightBox], sidebarAnchorX: CGFloat) {
        self.vocab = vocab
        self.refs = refs
        self.sidebarAnchorX = sidebarAnchorX
        pruneSidebarState()

        if layoutMode == .side {
            hovered = nil
            hoverTask?.cancel()
            hoverTask = nil
            preloadSidebarTooltips()
            render(hovered: nil, tooltip: nil)
            return
        }

        render(hovered: hovered, tooltip: nil)
    }

    func setLayoutMode(_ mode: OverlayAnnotationLayout) {
        layoutMode = mode
        applyOverlayFrame()

        if mode == .side {
            hovered = nil
            hoverTask?.cancel()
            hoverTask = nil
            pruneSidebarState()
            preloadSidebarTooltips()
            render(hovered: nil, tooltip: nil)
            return
        }

        render(hovered: nil, tooltip: nil)
    }

    func setDebugMode(_ enabled: Bool) {
        debugModeEnabled = enabled
        render(hovered: hovered, tooltip: nil)
    }

    func clear() {
        vocab = []
        refs = []
        lastOCRTokenRects = []
        hovered = nil
        sideTooltips.removeAll()
        sideLookupTasks.values.forEach { $0.cancel() }
        sideLookupTasks.removeAll()
        suppressedLookupKeys.removeAll()
        hoverTask?.cancel()
        hoverTask = nil
        render(hovered: nil, tooltip: nil)
    }

    private func startHoverPolling() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pollHover()
            }
        }
    }

    private func updateMousePassthrough() {
        let mouse = NSEvent.mouseLocation
        let winFrame = window.frame

        guard winFrame.contains(mouse) else {
            window.ignoresMouseEvents = true
            return
        }

        if layoutMode == .side, !targetFrame.isEmpty {
            // Content frame ends at targetFrame.width from the window's left edge.
            // To the right of that is the sidebar gutter — make it interactive.
            let sidebarStartX = winFrame.minX + targetFrame.width
            window.ignoresMouseEvents = mouse.x <= sidebarStartX
            return
        }

        if layoutMode == .hover, hovered != nil, let tooltipFrame {
            // Use the tooltip's actual rendered frame (reported via
            // TooltipFramePreferenceKey) so hit-testing adapts to variable
            // content height — e.g. multi-option pickers are taller than
            // single wiki/dictionary cards.
            let localX = mouse.x - winFrame.origin.x
            let localY = winFrame.height - (mouse.y - winFrame.origin.y) // flip to SwiftUI top-left coords
            if tooltipFrame.contains(CGPoint(x: localX, y: localY)) {
                window.ignoresMouseEvents = false
                return
            }
        }

        window.ignoresMouseEvents = true
    }

    private func pollHover() {
        updateMousePassthrough()

        guard layoutMode == .hover else {
            if hovered != nil {
                hovered = nil
                hoverTask?.cancel()
                hoverTask = nil
                render(hovered: nil, tooltip: nil)
            }
            return
        }

        let mouse = NSEvent.mouseLocation
        let winFrame = window.frame

        guard winFrame.contains(mouse) else {
            if hovered != nil {
                hovered = nil
                hoverTask?.cancel()
                hoverTask = nil
                render(hovered: nil, tooltip: nil)
            }
            return
        }

        let localX = mouse.x - winFrame.origin.x
        let localY = mouse.y - winFrame.origin.y
        let local = CGPoint(x: localX, y: localY)
        let overlayH = currentSize.height
        let localSwiftUI = CGPoint(x: local.x, y: overlayH - local.y)

        if let hit = visibleHighlights.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(localSwiftUI) }) {
            if hovered?.id != hit.id {
                hovered = hit
                hoverTask?.cancel()
                hoverTask = Task { [weak self] in
                    guard let self else { return }
                    await self.showToolTip(for: hit)
                }
            }
            return
        }

        // No auto-detected highlight — check if hovering any OCR token for
        // ad-hoc lookup (lets the user look up words the engine didn't pick).
        if let tokenMatch = lastOCRTokenRects.enumerated().first(where: {
            $0.element.rect.insetBy(dx: -1, dy: -1).contains(localSwiftUI)
        }) {
            let token = tokenMatch.element
            let idx = tokenMatch.offset

            let alreadyHovering = hovered.map { h in
                h.text == token.text &&
                abs(h.rect.midX - token.rect.midX) < 3 &&
                abs(h.rect.midY - token.rect.midY) < 3
            } ?? false

            if !alreadyHovering {
                let contextWindow = 15
                let start = max(0, idx - contextWindow)
                let end = min(lastOCRTokenRects.count, idx + contextWindow + 1)
                let ctxBefore = lastOCRTokenRects[start..<idx].map(\.text).joined(separator: " ")
                let ctxAfter = lastOCRTokenRects[(idx + 1)..<end].map(\.text).joined(separator: " ")

                let isCapitalized = token.text.first?.isUppercase ?? false
                let kind: HighlightBox.Kind = isCapitalized ? .reference : .vocab

                let adHoc = HighlightBox(
                    text: token.text, rect: token.rect, kind: kind,
                    contextBefore: ctxBefore, contextAfter: ctxAfter
                )

                if !suppressedLookupKeys.contains(lookupKey(for: adHoc)) {
                    hovered = adHoc
                    hoverTask?.cancel()
                    hoverTask = Task { [weak self] in
                        guard let self else { return }
                        await self.showToolTip(for: adHoc)
                    }
                }
            }
            return
        }

        // Mouse is NOT over a highlight or token. Before dismissing the
        // tooltip, keep it visible if the mouse is now over the tooltip card
        // itself — this is what lets users actually reach the Report button,
        // pick a candidate in the multi-option picker, etc. We also tolerate
        // a small "gap corridor" above the highlight for the trip from
        // highlight to card.
        if hovered != nil {
            let overTooltip: Bool = {
                guard let tooltipFrame else { return false }
                // tooltipFrame is in SwiftUI top-left overlay coordinates —
                // same space as localSwiftUI. Expand slightly to tolerate the
                // gap between the highlight and the card.
                return tooltipFrame.insetBy(dx: -6, dy: -6).contains(localSwiftUI)
            }()
            if overTooltip {
                return // stay hovered, keep the card visible
            }
            hovered = nil
            hoverTask?.cancel()
            hoverTask = nil
            render(hovered: nil, tooltip: nil)
        }
    }

    private func showToolTip(for h: HighlightBox) async {
        render(hovered: h, tooltip: .loading)
        let tooltip = await fetchTooltip(for: h)
        guard layoutMode == .hover, hovered?.id == h.id else { return }
        guard let tooltip else {
            suppressedLookupKeys.insert(lookupKey(for: h))
            hovered = nil
            render(hovered: nil, tooltip: nil)
            return
        }
        suppressedLookupKeys.remove(lookupKey(for: h))
        render(hovered: h, tooltip: tooltip)
    }

    private func render(hovered: HighlightBox?, tooltip: OverlayTooltip?) {
        host.rootView = OverlayView(
            vocab: filteredVocab,
            refs: filteredRefs,
            hovered: hovered,
            tooltip: tooltip,
            layoutMode: layoutMode,
            sideAnnotations: currentSidebarAnnotations(),
            sideRailWidth: sideRailWidth(for: window.frame),
            sidebarAnchorX: sidebarAnchorX,
            debugModeEnabled: debugModeEnabled,
            onReportErrata: { [weak self] phrase, annotation in
                self?.openErrataForm(phrase: phrase, annotation: annotation)
            },
            onCandidateSelected: { [weak self] highlight, selected, allCandidates in
                self?.selectCandidate(selected, forHighlight: highlight, allCandidates: allCandidates)
            },
            onCandidatesDismissed: { [weak self] highlight, requested, allCandidates in
                self?.dismissCandidates(forHighlight: highlight, requested: requested, allCandidates: allCandidates)
            },
            onTooltipFrameChanged: { [weak self] frame in
                guard let self else { return }
                self.tooltipFrame = frame
                self.updateMousePassthrough()
            }
        )
    }

    private func openErrataForm(phrase: String, annotation: String?) {
        // Browsers reliably accept URLs up to about 2,000 characters. Annotations
        // can contain full Wikipedia extracts or multi-sentence definitions, which
        // easily blows past that and would cause the browser to reject or truncate
        // the URL. Clamp each field individually and rely on URLComponents /
        // URLQueryItem to percent-encode.
        func clamp(_ s: String, _ maxChars: Int) -> String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > maxChars else { return trimmed }
            return String(trimmed.prefix(maxChars - 1)) + "\u{2026}" // ellipsis
        }

        var components = URLComponents(string: "https://summa-demo.josephruocco.net/feedback")!
        var items = [URLQueryItem(name: "phrase", value: clamp(phrase, 200))]
        if !windowLabel.isEmpty {
            items.append(URLQueryItem(name: "document", value: clamp(windowLabel, 200)))
        }
        if let annotation, !annotation.isEmpty {
            items.append(URLQueryItem(name: "annotation", value: clamp(annotation, 600)))
        }
        items.append(URLQueryItem(name: "type", value: "wrong-annotation"))
        components.queryItems = items
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    private func applyOverlayFrame() {
        guard !targetFrame.isEmpty else { return }
        window.setFrame(presentationFrame(for: targetFrame), display: true)
    }

    private func presentationFrame(for contentFrame: CGRect) -> CGRect {
        guard layoutMode == .side else { return contentFrame }

        let desiredExtraWidth = Self.sideRailGutterWidth + Self.sideRailOuterPadding
        let screenFrame = screenFrame(containing: contentFrame) ?? NSScreen.main?.visibleFrame ?? contentFrame
        let rightSpace = max(0, screenFrame.maxX - contentFrame.maxX)
        let extraWidth = min(desiredExtraWidth, rightSpace)

        guard extraWidth > 80 else { return contentFrame }

        return CGRect(
            x: contentFrame.minX,
            y: contentFrame.minY,
            width: contentFrame.width + extraWidth,
            height: contentFrame.height
        )
    }

    private func sideRailWidth(for frame: CGRect) -> CGFloat {
        max(0, frame.width - targetFrame.width)
    }

    private func screenFrame(containing frame: CGRect) -> CGRect? {
        let point = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first(where: { $0.visibleFrame.contains(point) })?.visibleFrame
    }

    private func normalizeKey(_ s: String) -> String {
        s.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’"))
    }

    private func orderedUniqueHighlights() -> [HighlightBox] {
        let ordered = visibleHighlights.sorted {
            if abs($0.rect.minY - $1.rect.minY) > 6 {
                return $0.rect.minY < $1.rect.minY
            }
            return $0.rect.minX < $1.rect.minX
        }

        var seen = Set<String>()
        var unique: [HighlightBox] = []

        for highlight in ordered {
            let key = sidebarKey(for: highlight)
            if seen.insert(key).inserted {
                unique.append(highlight)
            }
        }

        return unique
    }

    private func currentSidebarAnnotations() -> [OverlaySidebarAnnotation] {
        orderedUniqueHighlights().compactMap { highlight in
            let key = sidebarKey(for: highlight)
            guard let tooltip = sideTooltips[key] else { return nil }
            return OverlaySidebarAnnotation(id: key, highlight: highlight, tooltip: tooltip)
        }
    }

    private func pruneSidebarState() {
        let validKeys = Set(orderedUniqueHighlights().map(sidebarKey))
        sideTooltips = sideTooltips.filter { validKeys.contains($0.key) }
        let activeLookupKeys = Set((vocab + refs).map(lookupKey))
        suppressedLookupKeys = suppressedLookupKeys.filter { activeLookupKeys.contains($0) }

        for (key, task) in sideLookupTasks where !validKeys.contains(key) {
            task.cancel()
            sideLookupTasks.removeValue(forKey: key)
        }
    }

    private func preloadSidebarTooltips() {
        for highlight in orderedUniqueHighlights() {
            let key = sidebarKey(for: highlight)
            if sideTooltips[key] != nil || sideLookupTasks[key] != nil { continue }

            sideTooltips[key] = .loading
            sideLookupTasks[key] = Task { [weak self] in
                guard let self else { return }
                let tooltip = await self.fetchTooltip(for: highlight)

                await MainActor.run {
                    self.sideLookupTasks[key] = nil
                    guard self.layoutMode == .side else { return }
                    guard Set(self.orderedUniqueHighlights().map(self.sidebarKey)).contains(key) else { return }
                    if let tooltip {
                        self.suppressedLookupKeys.remove(self.lookupKey(for: highlight))
                        self.sideTooltips[key] = tooltip
                    } else {
                        self.suppressedLookupKeys.insert(self.lookupKey(for: highlight))
                        self.sideTooltips.removeValue(forKey: key)
                    }
                    self.render(hovered: nil, tooltip: nil)
                }
            }
        }
    }

    private func fetchTooltip(for h: HighlightBox) async -> OverlayTooltip? {
        let text = h.text
        let key = lookupKey(for: h)

        if h.kind == .vocab {
            if let cached = LookupCache.shared.dictionary(key) {
                return .dictionary(term: text, definition: cached)
            }

            let def = Lookups.definition(for: text) ?? "No dictionary entry found."
            LookupCache.shared.setDictionary(key, def)
            return .dictionary(term: text, definition: def)
        }

        if let cached = LookupCache.shared.multiOption(key) {
            return .multiOption(cached)
        }

        if let cached = LookupCache.shared.wikipedia(key) {
            return cached.status == .ok ? .wiki(cached) : nil
        }

        let lookupResult = await Wikipedia.lookupWithCandidates(text, contextBefore: h.contextBefore, contextAfter: h.contextAfter)
        switch lookupResult {
        case .single(let wiki):
            LookupCache.shared.setWikipedia(key, wiki)
            return wiki.status == .ok ? .wiki(wiki) : nil
        case .ambiguous(let candidateSet):
            LookupCache.shared.setMultiOption(key, candidateSet)
            return .multiOption(candidateSet)
        }
    }

    func selectCandidate(_ selected: WikiResult, forHighlight h: HighlightBox, allCandidates: [WikiResult] = []) {
        let key = lookupKey(for: h)
        let sKey = sidebarKey(for: h)
        LookupCache.shared.setWikipedia(key, selected) // also clears multiOption for this key
        TrainingDataStore.shared.recordSelection(
            highlight: h,
            windowLabel: windowLabel,
            selected: selected,
            allCandidates: allCandidates
        )

        if layoutMode == .side {
            sideTooltips[sKey] = .wiki(selected)
            render(hovered: nil, tooltip: nil)
        } else {
            render(hovered: hovered, tooltip: .wiki(selected))
        }
    }

    func dismissCandidates(forHighlight h: HighlightBox, requested: String, allCandidates: [WikiResult]) {
        let key = lookupKey(for: h)
        let sKey = sidebarKey(for: h)
        LookupCache.shared.clearMultiOption(key)
        suppressedLookupKeys.insert(key)
        sideTooltips.removeValue(forKey: sKey)
        hovered = nil
        TrainingDataStore.shared.recordDismissal(
            highlight: h,
            windowLabel: windowLabel,
            requested: requested,
            allCandidates: allCandidates
        )
        render(hovered: nil, tooltip: nil)
    }

    private func sidebarKey(for highlight: HighlightBox) -> String {
        let prefix = highlight.kind == .vocab ? "v" : "r"
        return "\(prefix)|\(normalizeKey(highlight.text))"
    }

    private var filteredVocab: [HighlightBox] {
        vocab.filter { !suppressedLookupKeys.contains(lookupKey(for: $0)) }
    }

    private var filteredRefs: [HighlightBox] {
        refs.filter { !suppressedLookupKeys.contains(lookupKey(for: $0)) }
    }

    private var visibleHighlights: [HighlightBox] {
        filteredVocab + filteredRefs
    }

    private func lookupKey(for highlight: HighlightBox) -> String {
        let prefix = highlight.kind == .vocab ? "v" : "r"
        let context = [highlight.contextBefore, highlight.contextAfter]
            .joined(separator: " ")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let signature = context
            .split(separator: " ")
            .prefix(10)
            .joined(separator: " ")

        if signature.isEmpty {
            return "\(prefix)|\(normalizeKey(highlight.text))"
        }

        return "\(prefix)|\(normalizeKey(highlight.text))|\(signature)"
    }
}

enum OverlayTooltip: Equatable {
    case loading
    case dictionary(term: String, definition: String)
    case wiki(WikiResult)
    case multiOption(WikiCandidateSet)
}
