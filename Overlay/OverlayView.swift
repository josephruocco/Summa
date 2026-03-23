import SwiftUI

struct OverlayView: View {
    let vocab: [HighlightBox]
    let refs: [HighlightBox]
    let hovered: HighlightBox?
    let tooltip: OverlayTooltip?
    let layoutMode: OverlayAnnotationLayout
    let sideAnnotations: [OverlaySidebarAnnotation]

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

                if layoutMode == .side, !sideAnnotations.isEmpty {
                    SidebarRail(
                        sideAnnotations: sideAnnotations,
                        overlaySize: size,
                        colorForTerm: color(for:)
                    )
                }

                if layoutMode == .hover, let hovered, let tooltip {
                    TooltipCard(hovered: hovered, tooltip: tooltip, overlaySize: size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .allowsHitTesting(false)
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
        let colorForTerm: (String) -> Color

        var body: some View {
            let horizontalPadding: CGFloat = overlaySize.width < 760 ? 10 : 14
            let verticalPadding: CGFloat = 12
            let spacing: CGFloat = sideAnnotations.count > 10 ? 6 : 10
            let preferredWidth = overlaySize.width < 900 ? overlaySize.width * 0.30 : overlaySize.width * 0.24
            let sidebarWidth = min(max(200, preferredWidth), max(180, overlaySize.width - horizontalPadding * 2))
            let usableHeight = max(140, overlaySize.height - verticalPadding * 2)
            let cardBudget = (usableHeight - spacing * CGFloat(max(sideAnnotations.count - 1, 0))) / CGFloat(max(sideAnnotations.count, 1))
            let cardHeight = min(170, max(44, cardBudget))

            HStack {
                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(sideAnnotations) { annotation in
                        SidebarCard(
                            annotation: annotation,
                            color: colorForTerm(annotation.highlight.text),
                            maxHeight: cardHeight
                        )
                    }
                }
                .frame(width: sidebarWidth)
                .padding(.top, verticalPadding)
                .padding(.trailing, horizontalPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private struct SidebarCard: View {
        let annotation: OverlaySidebarAnnotation
        let color: Color
        let maxHeight: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(annotation.highlight.text)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)

                switch annotation.tooltip {
                case .loading:
                    Text("Loading…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .dictionary(_, let definition):
                    Text(definition)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(bodyLineLimit)
                case .wiki(let result):
                    if let title = result.title, !title.isEmpty, title.caseInsensitiveCompare(annotation.highlight.text) != .orderedSame {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Text(wikiText(result))
                        .font(.system(size: 11))
                        .foregroundStyle(result.status == .ok ? .primary : .secondary)
                        .lineLimit(bodyLineLimit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(color.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color.opacity(0.95), lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        private var bodyLineLimit: Int {
            max(2, Int((maxHeight - 24) / 15))
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
            }
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

                    if let page = r.pageURL, !page.isEmpty {
                        Text(page)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }

        private func wikiText(_ r: WikiResult) -> String {
            switch r.status {
            case .ok:
                return (r.extract?.isEmpty == false) ? r.extract! : "No summary text found."
            case .notFound:
                return "No Wikipedia page found."
            case .disambiguation:
                return (r.extract?.isEmpty == false) ? r.extract! : "Ambiguous term—picked the closest match."
            case .error:
                return (r.extract?.isEmpty == false) ? r.extract! : "Wikipedia lookup failed."
            }
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
