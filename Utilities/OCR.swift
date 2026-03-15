@preconcurrency import Vision
import Foundation
import CoreGraphics

struct OCRToken: Hashable, Identifiable {
    let id = UUID()
    let text: String
    let rectNorm: CGRect // Vision normalized [0,1], origin bottom-left
}

enum OCR {
    struct CropProfile {
        let normalizedRect: CGRect
    }

    static func ocrTokens(from cgImage: CGImage, cropProfile: CropProfile? = nil) async -> [OCRToken] {
        let crop = sanitizeCrop(cropProfile?.normalizedRect)
        let croppedImage = crop.flatMap { cropCGImage(cgImage, normalizedRect: $0) } ?? cgImage

        let rawTokens: [OCRToken] = await withCheckedContinuation { cont in
            let req = VNRecognizeTextRequest { request, _ in
                let obs = (request.results as? [VNRecognizedTextObservation]) ?? []
                var out: [OCRToken] = []

                for o in obs {
                    guard let best = o.topCandidates(1).first else { continue }
                    let full = best.string
                    if full.isEmpty { continue }

                    let pattern = #"[A-Za-z][A-Za-z'\-]*"#
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                    let ns = full as NSString
                    let matches = regex.matches(in: full, range: NSRange(location: 0, length: ns.length))

                    for m in matches {
                        let word = ns.substring(with: m.range)
                        guard let swiftRange = Range(m.range, in: full) else {
                            out.append(OCRToken(text: word, rectNorm: o.boundingBox))
                            continue
                        }

                        if let box = try? best.boundingBox(for: swiftRange) {
                            out.append(OCRToken(text: word, rectNorm: box.boundingBox))
                        } else {
                            out.append(OCRToken(text: word, rectNorm: o.boundingBox))
                        }
                    }
                }

                cont.resume(returning: out)
            }

            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: croppedImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([req])
            }
        }

        guard let crop else { return rawTokens }
        return rawTokens.map { token in
            OCRToken(text: token.text, rectNorm: remapFromCrop(token.rectNorm, crop: crop))
        }
    }

    static func cropProfile(forWindowLabel label: String) -> CropProfile? {
        let lowered = label.lowercased()
        let browserHints = ["google chrome", "chrome", "safari", "arc", "firefox", "brave", "edge", "opera", "browser"]
        guard browserHints.contains(where: { lowered.contains($0) }) else { return nil }

        return CropProfile(
            normalizedRect: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 0.88)
        )
    }

    static func normToRectInOverlay_TopLeftOrigin(_ r: CGRect, overlaySize: CGSize) -> CGRect {
        let x = r.origin.x * overlaySize.width
        let y = (1.0 - r.origin.y - r.size.height) * overlaySize.height
        let w = r.size.width * overlaySize.width
        let h = r.size.height * overlaySize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func sanitizeCrop(_ rect: CGRect?) -> CGRect? {
        guard var rect else { return nil }
        rect.origin.x = max(0, min(1, rect.origin.x))
        rect.origin.y = max(0, min(1, rect.origin.y))
        rect.size.width = max(0, min(1 - rect.origin.x, rect.size.width))
        rect.size.height = max(0, min(1 - rect.origin.y, rect.size.height))
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private static func cropCGImage(_ image: CGImage, normalizedRect: CGRect) -> CGImage? {
        let pxRect = CGRect(
            x: normalizedRect.minX * CGFloat(image.width),
            y: (1.0 - normalizedRect.minY - normalizedRect.height) * CGFloat(image.height),
            width: normalizedRect.width * CGFloat(image.width),
            height: normalizedRect.height * CGFloat(image.height)
        ).integral

        guard pxRect.width > 0, pxRect.height > 0 else { return nil }
        return image.cropping(to: pxRect)
    }

    private static func remapFromCrop(_ rect: CGRect, crop: CGRect) -> CGRect {
        CGRect(
            x: crop.minX + rect.minX * crop.width,
            y: crop.minY + rect.minY * crop.height,
            width: rect.width * crop.width,
            height: rect.height * crop.height
        )
    }
}
