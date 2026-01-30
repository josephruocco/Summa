import SwiftUI

struct OverlayView: View {
    let vocab: [HighlightBox]
    let refs: [HighlightBox]
    let hovered: HighlightBox?
    let tooltip: String?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {

                ForEach(vocab) { h in
                    Rectangle()
                        .fill(Color.green.opacity(0.22))
                        .frame(width: h.rect.width, height: h.rect.height)
                        .position(x: h.rect.midX, y: h.rect.midY)
                }

                ForEach(refs) { h in
                    Rectangle()
                        .fill(Color.blue.opacity(0.20))
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
            .allowsHitTesting(false) // overlay stays pass-through
        }
    }

    private func clamp(_ v: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, v))
    }
}
