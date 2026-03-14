import Combine
import Foundation

@MainActor
final class OverlayState: ObservableObject {
    @Published var vocab: [HighlightBox] = []
    @Published var refs: [HighlightBox] = []

    @Published var hovered: HighlightBox? = nil
    @Published var tooltip: String? = nil
}
