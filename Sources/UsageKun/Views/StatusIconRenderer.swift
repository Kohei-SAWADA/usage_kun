import AppKit
import SwiftUI
import UsageKunCore

extension UsageStatus {
    var menuBarColor: NSColor {
        switch self {
        case .ok, .unknown:
            .labelColor
        case .warning:
            .systemOrange
        case .critical, .error:
            .systemRed
        }
    }
}

enum StatusIconRenderer {
    static func image(percent: Double, status: UsageStatus) -> NSImage {
        let size = NSSize(width: 26, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        let rect = NSRect(origin: .zero, size: size)
        NSColor.clear.setFill()
        rect.fill()

        let track = NSBezierPath(roundedRect: NSRect(x: 2, y: 5, width: 22, height: 8), xRadius: 2, yRadius: 2)
        NSColor(red: 0.16, green: 0.34, blue: 0.22, alpha: 0.55).setFill()
        track.fill()

        let clamped = min(max(percent, 0), 100)
        let fillWidth = max(2, 22 * clamped / 100)
        let fill = NSBezierPath(roundedRect: NSRect(x: 2, y: 5, width: fillWidth, height: 8), xRadius: 2, yRadius: 2)
        NSColor(status.tint).setFill()
        fill.fill()

        if status == .warning || status == .critical || status == .error {
            let dot = NSBezierPath(ovalIn: NSRect(x: 18, y: 11, width: 6, height: 6))
            NSColor(status.tint).setFill()
            dot.fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
