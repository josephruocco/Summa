@preconcurrency import Vision
import Foundation
import CoreGraphics

struct OCRToken: Hashable, Identifiable {
    let id = UUID()
    let text: String
    let rectNorm: CGRect // Vision normalized [0,1], origin bottom-left
}

enum OCR {
    static func ocrTokens(from cgImage: CGImage) async -> [OCRToken] {
        await withCheckedContinuation { cont in
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

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                try? handler.perform([req])
            }
        }
    }

    // Convert Vision normalized (bottom-left origin) -> overlay-local (TOP-left origin) in points
    static func normToRectInOverlay_TopLeftOrigin(_ r: CGRect, overlaySize: CGSize) -> CGRect {
        let x = r.origin.x * overlaySize.width
        let y = (1.0 - r.origin.y - r.size.height) * overlaySize.height
        let w = r.size.width * overlaySize.width
        let h = r.size.height * overlaySize.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
