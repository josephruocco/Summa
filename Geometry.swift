import CoreGraphics

enum Geometry {
    nonisolated static func visionNormToOverlayTopLeft(_ r: CGRect, overlaySize: CGSize) -> CGRect {
        let x = r.origin.x * overlaySize.width
        let y = (1.0 - r.origin.y - r.size.height) * overlaySize.height
        let w = r.size.width * overlaySize.width
        let h = r.size.height * overlaySize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
