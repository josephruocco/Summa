import Foundation
import CoreGraphics
import AppKit

enum WindowBounds {
    static func boundsForWindow(windowID: UInt32) -> CGRect? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard
            let infoList = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
            let info = infoList.first,
            let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
            let x = boundsDict["X"] as? CGFloat,
            let y = boundsDict["Y"] as? CGFloat,
            let w = boundsDict["Width"] as? CGFloat,
            let h = boundsDict["Height"] as? CGFloat
        else { return nil }

        guard let screen = NSScreen.main else {
            return CGRect(x: x, y: y, width: w, height: h)
        }

        let screenH = screen.frame.height
        let cocoaY = screenH - y - h
        return CGRect(x: x, y: cocoaY, width: w, height: h)
    }

    static func frontmostWindowID(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> UInt32? {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != excludingPID else { continue }

            if let frontmostPID, ownerPID != frontmostPID { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0 else { continue }

            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 220,
                  height > 140 else { continue }

            if let id = info[kCGWindowNumber as String] as? UInt32 {
                return id
            }
            if let id = info[kCGWindowNumber as String] as? NSNumber {
                return id.uint32Value
            }
        }

        return nil
    }
}
