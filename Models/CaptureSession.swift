import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreImage
import AppKit

struct CapturedFrame {
    let cgImage: CGImage
    let size: CGSize
}

final class CaptureSession: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private let ciContext = CIContext(options: nil)
    private var onFrame: ((CapturedFrame) -> Void)?

    func startCapturing(window: SCWindow, onFrame: @escaping (CapturedFrame) -> Void) async throws {
        self.onFrame = onFrame

        let filter = SCContentFilter(desktopIndependentWindow: window)

        // Low FPS is enough (and keeps CPU sane)
        let config = SCStreamConfiguration()
        config.minimumFrameInterval = CMTime(value: 1, timescale: 6) // ~6 FPS
        config.queueDepth = 3
        config.capturesAudio = false

        // Start with a reasonable size; OCR works better if not too tiny
        config.width = Int(window.frame.width)
        config.height = Int(window.frame.height)

        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "scstream.frames"))
        try await s.startCapture()

        self.stream = s
    }

    func stop() {
        guard let stream else { return }
        Task {
            try? await stream.stopCapture()
        }
        self.stream = nil
        self.onFrame = nil
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        onFrame?(CapturedFrame(cgImage: cgImage, size: size))
    }
}
