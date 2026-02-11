import Foundation
import CoreGraphics
import QuartzCore

final class ChangeGate {
    private var lastHash: UInt64 = 0
    private var lastTime: CFTimeInterval = 0

    // Tweak these
    private let minInterval: CFTimeInterval = 0.25
    private let hashStride: Int = 8

    func shouldProcess(image: CGImage) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastTime < minInterval { return false }

        let h = quickHash(image)
        if h == lastHash { return false }

        lastHash = h
        lastTime = now
        return true
    }

    private func quickHash(_ image: CGImage) -> UInt64 {
        // Very cheap: hash dimensions + sample some bytes from raw BGRA buffer if available.
        // If you don’t have raw bytes, this still helps via dims.
        var x: UInt64 = 1469598103934665603 // FNV offset
        func mix(_ v: UInt64) { x = (x ^ v) &* 1099511628211 }

        mix(UInt64(image.width))
        mix(UInt64(image.height))
        mix(UInt64(image.bitsPerPixel))
        mix(UInt64(image.bytesPerRow))

        // Optional: if data provider gives bytes, sample a few.
        if let data = image.dataProvider?.data,
           let ptr = CFDataGetBytePtr(data) {
            let len = CFDataGetLength(data)
            if len > 0 {
                var i = 0
                while i < len {
                    mix(UInt64(ptr[i]))
                    i += max(1, len / 64) // sample ~64 bytes max
                }
            }
        }
        return x
    }
}
