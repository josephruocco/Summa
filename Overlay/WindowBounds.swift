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

        // Quartz window bounds commonly use a top-left origin;
        // Cocoa expects bottom-left. Flip using the screen height.
        guard let screen = NSScreen.main else {
            return CGRect(x: x, y: y, width: w, height: h)
        }

        let screenH = screen.frame.height
        let cocoaY = screenH - y - h
        return CGRect(x: x, y: cocoaY, width: w, height: h)
    }
}
