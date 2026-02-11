import SwiftUI

struct OverlayView: View {
    let vocab: [HighlightBox]
    let refs: [HighlightBox]
    let hovered: HighlightBox?
    let tooltip: String?

    private let palette: [Color] = [
        Color(red: 0.55, green: 0.85, blue: 0.87), // teal
        Color(red: 0.98, green: 0.90, blue: 0.45), // yellow
        Color(red: 0.98, green: 0.55, blue: 0.55), // red
        Color(red: 0.55, green: 0.90, blue: 0.55)  // green
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

                if let hovered, let tooltip {
                    let boxW: CGFloat = 360
                    let x = clamp(hovered.rect.midX, min: boxW/2 + 12, max: size.width - boxW/2 - 12)
                    let y = max(hovered.rect.minY - 70, 70)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(hovered.text)
                            .font(.system(size: 13, weight: .semibold))
                        Text(tooltip)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.clear)
            .allowsHitTesting(false)
        }
    }

    private func color(for term: String) -> Color {
        // normalize so "Egyptians," and "Egyptians" map the same
        let normalized = term
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’"))

        let idx = stableIndex(normalized, mod: palette.count)
        return palette[idx]
    }

    private func stableIndex(_ s: String, mod: Int) -> Int {
        // deterministic across runs (unlike Swift's Hasher)
        var hash: UInt64 = 1469598103934665603 // FNV-1a offset basis
        for b in s.utf8 {
            hash ^= UInt64(b)
            hash &*= 1099511628211 // FNV prime
        }
        return Int(hash % UInt64(mod))
    }

    private func clamp(_ v: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, v))
    }
}
