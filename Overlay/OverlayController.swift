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

    private var hoverTimer: Timer?
    private var hovered: HighlightBox?
    private var hoverTask: Task<Void, Never>?
    private var targetFrame: CGRect = .zero
    private var sidebarAnchorX: CGFloat = 0

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
            sidebarAnchorX: 0
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

    func setOverlayFrame(_ frame: CGRect) {
        targetFrame = frame
        applyOverlayFrame()
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

    func clear() {
        vocab = []
        refs = []
        hovered = nil
        sideTooltips.removeAll()
        sideLookupTasks.values.forEach { $0.cancel() }
        sideLookupTasks.removeAll()
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

    private func pollHover() {
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

        if let hit = (vocab + refs).first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(localSwiftUI) }) {
            if hovered?.id != hit.id {
                hovered = hit
                hoverTask?.cancel()
                hoverTask = Task { [weak self] in
                    guard let self else { return }
                    await self.showToolTip(for: hit)
                }
            }
        } else if hovered != nil {
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
        render(hovered: h, tooltip: tooltip)
    }

    private func render(hovered: HighlightBox?, tooltip: OverlayTooltip?) {
        host.rootView = OverlayView(
            vocab: vocab,
            refs: refs,
            hovered: hovered,
            tooltip: tooltip,
            layoutMode: layoutMode,
            sideAnnotations: currentSidebarAnnotations(),
            sideRailWidth: sideRailWidth(for: window.frame),
            sidebarAnchorX: sidebarAnchorX
        )
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
        let ordered = (vocab + refs).sorted {
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
                    self.sideTooltips[key] = tooltip
                    self.render(hovered: nil, tooltip: nil)
                }
            }
        }
    }

    private func fetchTooltip(for h: HighlightBox) async -> OverlayTooltip {
        let text = h.text
        let key = normalizeKey(text)

        if h.kind == .vocab {
            if let cached = LookupCache.shared.dictionary(key) {
                return .dictionary(term: text, definition: cached)
            }

            let def = Lookups.definition(for: text) ?? "No dictionary entry found."
            LookupCache.shared.setDictionary(key, def)
            return .dictionary(term: text, definition: def)
        }

        if let cached = LookupCache.shared.wikipedia(key) {
            return .wiki(cached)
        }

        let wiki = await Wikipedia.lookup(text, contextBefore: nil, contextAfter: nil)
        LookupCache.shared.setWikipedia(key, wiki)
        return .wiki(wiki)
    }

    private func sidebarKey(for highlight: HighlightBox) -> String {
        let prefix = highlight.kind == .vocab ? "v" : "r"
        return "\(prefix)|\(normalizeKey(highlight.text))"
    }
}

enum OverlayTooltip: Equatable {
    case loading
    case dictionary(term: String, definition: String)
    case wiki(WikiResult)
}
