import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private let window: NSPanel
    private let host: NSHostingView<OverlayView>

    private var vocab: [HighlightBox] = []
    private var refs: [HighlightBox] = []

    private var hoverTimer: Timer?
    private var hovered: HighlightBox?
    private var hoverTask: Task<Void, Never>?

    var currentSize: CGSize { window.contentView?.bounds.size ?? .zero }

    init() {
        let view = OverlayView(vocab: [], refs: [], hovered: nil, tooltip: nil)
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
        window.ignoresMouseEvents = true // pass-through
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        window.contentView = host
        window.orderFrontRegardless()

        startHoverPolling()
    }

    func setOverlayFrame(_ frame: CGRect) {
        window.setFrame(frame, display: true)
    }

    func setHighlights(vocab: [HighlightBox], refs: [HighlightBox]) {
        self.vocab = vocab
        self.refs = refs
        render(hovered: hovered, tooltip: nil)
    }

    func clear() {
        vocab = []
        refs = []
        hovered = nil
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
        let mouse = NSEvent.mouseLocation // global screen coords, origin bottom-left
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

        // Convert to overlay-local coordinates (BOTTOM-left origin for hit test)
        let localX = mouse.x - winFrame.origin.x
        let localY = mouse.y - winFrame.origin.y
        let local = CGPoint(x: localX, y: localY)

        // IMPORTANT:
        // Our HighlightBox.rect is TOP-left origin (SwiftUI coords),
        // but local is BOTTOM-left origin.
        // Convert local -> SwiftUI y by flipping:
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
        } else {
            if hovered != nil {
                hovered = nil
                hoverTask?.cancel()
                hoverTask = nil
                render(hovered: nil, tooltip: nil)
            }
        }
    }

    private func showToolTip(for h: HighlightBox) async {
        render(hovered: h, tooltip: "Loading…")

        let text = h.text
        let kind = h.kind

        let result: String = await Task.detached(priority: .userInitiated) {
            if kind == .vocab {
                return Lookups.definition(for: text) ?? "No dictionary entry found."
            } else {
                return "Reference: \(text)"
            }
        }.value

        // don’t overwrite if hover changed
        guard hovered?.id == h.id else { return }
        render(hovered: h, tooltip: result)
    }

    private func render(hovered: HighlightBox?, tooltip: String?) {
        host.rootView = OverlayView(vocab: vocab, refs: refs, hovered: hovered, tooltip: tooltip)
    }
}
