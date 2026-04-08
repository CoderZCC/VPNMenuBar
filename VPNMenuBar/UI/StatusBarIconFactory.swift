import AppKit
import SwiftUI

/// Builds the status-bar icon for a given VPN state:
/// a template SF Symbol ("lock.shield") with a small colored dot overlay.
enum StatusBarIconFactory {
    static func image(for state: VPNState) -> NSImage {
        let baseSize = NSSize(width: 22, height: 18)
        let iconSize = NSSize(width: 16, height: 16)

        let result = NSImage(size: baseSize)
        result.lockFocus()
        defer { result.unlockFocus() }

        // 1. Base SF Symbol (lock.shield) rendered as template so it follows menu tint.
        if let base = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "VPN") {
            base.isTemplate = true
            base.size = iconSize
            base.draw(
                in: NSRect(x: 0, y: 1, width: iconSize.width, height: iconSize.height),
                from: .zero,
                operation: .sourceOver,
                fraction: state == .disconnected ? 0.55 : 1.0
            )
        }

        // 2. Colored status dot in the top-right corner.
        let dotRect = NSRect(x: baseSize.width - 7, y: baseSize.height - 7, width: 6, height: 6)
        let path = NSBezierPath(ovalIn: dotRect)
        dotColor(for: state).setFill()
        path.fill()

        result.isTemplate = false  // dot is colored, so we can't be a pure template.
        return result
    }

    private static func dotColor(for state: VPNState) -> NSColor {
        switch state {
        case .connected:          return NSColor.systemGreen
        case .connecting:         return NSColor.systemOrange
        case .failed:             return NSColor.systemRed
        case .disconnected:       return NSColor.systemGray
        }
    }
}
