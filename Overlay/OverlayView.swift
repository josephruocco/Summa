import SwiftUI

struct OverlayView: View {
    let vocab: [HighlightBox]
    let refs: [HighlightBox]
    let hovered: HighlightBox?
    let tooltip: OverlayTooltip?
    let layoutMode: OverlayAnnotationLayout
    let sideAnnotations: [OverlaySidebarAnnotation]
    let sideRailWidth: CGFloat
    let sidebarAnchorX: CGFloat
    let debugModeEnabled: Bool

    private let palette: [Color] = [
        Color(red: 0.55, green: 0.85, blue: 0.87),
        Color(red: 0.98, green: 0.90, blue: 0.45),
        Color(red: 0.98, green: 0.55, blue: 0.55),
        Color(red: 0.55, green: 0.90, blue: 0.55)
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                // Highlight boxes — always non-interactive so mouse events pass through to the page
                ZStack {
                    ForEach(vocab) { h in
                        let c = color(for: h.text)
                        Rectangle()
                            .fill(c.opacity(0.18))
                            .overlay(Rectangle().stroke(c.opacity(0.95), lineWidth: 2))
                            .frame(width: h.rect.width, height: h.rect.height)
                            .position(x: h.rect.midX, y: h.rect.midY)
                    }

                    ForEach(refs) { h in
                        let c = color(for: h.text)
                        Rectangle()
                            .fill(c.opacity(0.18))
                            .overlay(Rectangle().stroke(c.opacity(0.95), lineWidth: 2))
                            .frame(width: h.rect.width, height: h.rect.height)
                            .position(x: h.rect.midX, y: h.rect.midY)
                    }
                }
                .allowsHitTesting(false)

                // Sidebar rail — interactive when mouse enters the gutter (managed by OverlayController)
                if layoutMode == .side, !sideAnnotations.isEmpty {
                    SidebarRail(
                        sideAnnotations: sideAnnotations,
                        overlaySize: size,
                        sideRailWidth: sideRailWidth,
                        sidebarAnchorX: sidebarAnchorX,
                        debugModeEnabled: debugModeEnabled,
                        colorForTerm: color(for:)
                    )
                }

                if layoutMode == .hover, let hovered, let tooltip {
                    TooltipCard(hovered: hovered, tooltip: tooltip, overlaySize: size)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
        }
    }

    private struct TooltipCard: View {
        let hovered: HighlightBox
        let tooltip: OverlayTooltip
        let overlaySize: CGSize

        var body: some View {
            let boxW = max(220, min(380, overlaySize.width - 24))
            let x = clamp(hovered.rect.midX, min: boxW/2 + 12, max: overlaySize.width - boxW/2 - 12)
            let y = max(hovered.rect.minY - 82, 84)

            VStack(alignment: .leading, spacing: 8) {
                Text(hovered.text)
                    .font(.system(size: 13, weight: .semibold))

                switch tooltip {
                case .loading:
                    Text("Loading…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                case .dictionary(_, let def):
                    Text(def)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                case .wiki(let r):
                    WikiBlock(r: r)
                }
            }
            .padding(10)
            .background(.ultraThinMaterial)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            )
            .frame(width: boxW, alignment: .leading)
            .position(x: x, y: y)
        }

        private func clamp(_ v: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
            Swift.max(min, Swift.min(max, v))
        }
    }

    private struct SidebarRail: View {
        let sideAnnotations: [OverlaySidebarAnnotation]
        let overlaySize: CGSize
        let sideRailWidth: CGFloat
        let sidebarAnchorX: CGFloat
        let debugModeEnabled: Bool
        let colorForTerm: (String) -> Color

        var body: some View {
            let visibleCount = min(sideAnnotations.count, maxVisibleCards)
            let visibleAnnotations = Array(sideAnnotations.prefix(visibleCount))
            let hiddenCount = max(0, sideAnnotations.count - visibleCount)
            let verticalPadding: CGFloat = 12
            let spacing: CGFloat = 10
            let reservedWidth = max(0, sideRailWidth)
            let railContainerPadding: CGFloat = reservedWidth > 0 ? 8 : 10
            let preferredSidebarWidth: CGFloat = 352
            let minimumSidebarWidth: CGFloat = 248
            let gutterWidth = max(0, reservedWidth - railContainerPadding * 2)
            let fallbackWidth = min(preferredSidebarWidth, max(minimumSidebarWidth, overlaySize.width * 0.30))
            let sidebarWidth = reservedWidth > 0
                ? max(minimumSidebarWidth, min(preferredSidebarWidth, gutterWidth))
                : fallbackWidth
            let gutterStartX = max(0, overlaySize.width - reservedWidth)
            let fallbackLeftEdge = max(0, overlaySize.width - sidebarWidth - 8)
            let sidebarLeftEdge = reservedWidth > 0
                ? gutterStartX + 4
                : min(
                    max(sidebarAnchorX + 8, 0),
                    fallbackLeftEdge
                )

            VStack(alignment: .leading, spacing: spacing) {
                ForEach(visibleAnnotations) { annotation in
                    SidebarCard(
                        annotation: annotation,
                        color: colorForTerm(annotation.highlight.text),
                        maxHeight: debugModeEnabled ? 196 : 168,
                        debugModeEnabled: debugModeEnabled
                    )
                }

                if hiddenCount > 0 {
                    Text("+\(hiddenCount) more notes")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.black.opacity(0.72))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(red: 0.97, green: 0.97, blue: 0.95))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.black.opacity(0.10), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .frame(width: sidebarWidth)
            .padding(.horizontal, railContainerPadding)
            .padding(.top, verticalPadding)
            .padding(.bottom, verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.985, green: 0.982, blue: 0.96).opacity(0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
            .padding(.top, 8)
            .offset(x: sidebarLeftEdge, y: 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }

        private var maxVisibleCards: Int {
            overlaySize.height < 760 ? 6 : 8
        }
    }

    private struct SidebarCard: View {
        let annotation: OverlaySidebarAnnotation
        let color: Color
        let maxHeight: CGFloat
        let debugModeEnabled: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Capsule()
                        .fill(color.opacity(0.95))
                        .frame(width: 7, height: 7)

                    Text(annotation.highlight.text)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.88))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }

                switch annotation.tooltip {
                case .loading:
                    Text("Loading…")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.52))
                        .lineLimit(1)
                case .dictionary(_, let definition):
                    Text(definition)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.84))
                        .lineLimit(bodyLineLimit)
                case .wiki(let result):
                    if let title = result.title, !title.isEmpty, title.caseInsensitiveCompare(annotation.highlight.text) != .orderedSame {
                        Text(title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.72))
                            .lineLimit(1)
                    }

                    Text(wikiText(result))
                        .font(.system(size: 12))
                        .foregroundStyle(result.status == .ok ? Color.black.opacity(0.84) : Color.black.opacity(0.58))
                        .lineLimit(bodyLineLimit)

                    if result.status == .ok, let page = result.pageURL, !page.isEmpty, let url = URL(string: page) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Text("Open in Wikipedia →")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.88))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 2)
                    }

                    if debugModeEnabled {
                        debugInfo(for: result)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 0, maxHeight: maxHeight, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(mix(color, with: .white, amount: 0.86))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color.opacity(0.98), lineWidth: 1.4)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        private var bodyLineLimit: Int {
            max(3, Int((maxHeight - 28) / 17))
        }

        private func wikiText(_ result: WikiResult) -> String {
            switch result.status {
            case .ok:
                return (result.extract?.isEmpty == false) ? result.extract! : "No summary text found."
            case .notFound:
                return "No Wikipedia page found."
            case .disambiguation:
                return (result.extract?.isEmpty == false) ? result.extract! : "Ambiguous term."
            case .error:
                return (result.extract?.isEmpty == false) ? result.extract! : "Wikipedia lookup failed."
            case .suppressed:
                return (result.extract?.isEmpty == false) ? result.extract! : "Suppressed low-confidence match."
            }
        }

        @ViewBuilder
        private func debugInfo(for result: WikiResult) -> some View {
            let parts = [
                result.score.map { String(format: "score %.2f", $0) },
                result.debug
            ].compactMap { $0 }.filter { !$0.isEmpty }

            if !parts.isEmpty {
                Text(parts.joined(separator: " | "))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.black.opacity(0.50))
                    .lineLimit(3)
            }
        }

        private func mix(_ a: Color, with b: Color, amount: CGFloat) -> Color {
            let t = max(0, min(1, amount))

            #if os(macOS)
            let na = NSColor(a).usingColorSpace(.deviceRGB) ?? .white
            let nb = NSColor(b).usingColorSpace(.deviceRGB) ?? .white

            let r = na.redComponent * (1 - t) + nb.redComponent * t
            let g = na.greenComponent * (1 - t) + nb.greenComponent * t
            let bl = na.blueComponent * (1 - t) + nb.blueComponent * t

            return Color(red: r, green: g, blue: bl)
            #else
            return a
            #endif
        }
    }

    private struct WikiBlock: View {
        let r: WikiResult

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                if let s = r.thumbnailURL, let url = URL(string: s) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            RoundedRectangle(cornerRadius: 6)
                                .frame(width: 56, height: 56)
                                .opacity(0.15)
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: 56, height: 56)
                                .clipped()
                                .cornerRadius(6)
                        case .failure:
                            RoundedRectangle(cornerRadius: 6)
                                .frame(width: 56, height: 56)
                                .opacity(0.10)
                        @unknown default:
                            EmptyView()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let title = r.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                    }

                    Text(wikiText(r))
                        .font(.system(size: 12))
                        .foregroundStyle(r.status == .ok ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if r.status == .ok, let page = r.pageURL, !page.isEmpty, let url = URL(string: page) {
                        HStack {
                            Spacer()
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(red: 0.18, green: 0.42, blue: 0.88))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }

        private func wikiText(_ r: WikiResult) -> String {
            switch r.status {
            case .ok:
                return firstSentence(r.extract) ?? "No summary text found."
            case .notFound:
                return "No Wikipedia page found."
            case .disambiguation:
                return firstSentence(r.extract) ?? "Ambiguous term—picked the closest match."
            case .error:
                return firstSentence(r.extract) ?? "Wikipedia lookup failed."
            case .suppressed:
                return firstSentence(r.extract) ?? "Suppressed low-confidence match."
            }
        }

        private func firstSentence(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return nil }
            if let range = text.range(of: #"[.!?](?=\s|$)"#, options: .regularExpression) {
                return String(text[text.startIndex..<range.upperBound])
            }
            return text
        }
    }

    private func color(for term: String) -> Color {
        let normalized = term
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’"))

        let idx = stableIndex(normalized, mod: palette.count)
        return palette[idx]
    }

    private func stableIndex(_ s: String, mod: Int) -> Int {
        var hash: UInt64 = 1469598103934665603
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211
        }
        return Int(hash % UInt64(mod))
    }
}
