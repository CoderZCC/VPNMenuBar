import AppKit
import SwiftUI

/// Builds the status-bar icon: white rounded-rect badge with a shield symbol
/// and a colored status dot in the top-right corner.
enum StatusBarIconFactory {
    static func image(for state: VPNState) -> NSImage {
        let size = NSSize(width: 20, height: 18)
        let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0

        // Draw into a CGContext so we can use .destinationOut for the cutout
        let pxW = Int(size.width * scale)
        let pxH = Int(size.height * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return NSImage() }

        ctx.scaleBy(x: scale, y: scale)
        let gfx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfx

        // 1. White rounded-rect background
        let bgRect = NSRect(x: 0, y: 0, width: 18, height: 18)
        let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4)
        NSColor.white.setFill()
        bgPath.fill()

        // 2. Punch out the shield shape (cutout / knockout)
        //    Render SF Symbol into a separate CGImage first, then composite
        //    with destinationOut directly on the CGContext.
        if let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(paletteColors: [.black])
            if let tinted = symbol.withSymbolConfiguration(config) {
                let symbolSize = NSSize(width: 12, height: 12)
                let symPxW = Int(symbolSize.width * scale)
                let symPxH = Int(symbolSize.height * scale)
                if let symCtx = CGContext(
                    data: nil, width: symPxW, height: symPxH,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) {
                    symCtx.scaleBy(x: scale, y: scale)
                    let symGfx = NSGraphicsContext(cgContext: symCtx, flipped: false)
                    NSGraphicsContext.current = symGfx
                    tinted.draw(in: NSRect(origin: .zero, size: symbolSize))
                    NSGraphicsContext.current = gfx

                    if let symCG = symCtx.makeImage() {
                        let originX = bgRect.midX - symbolSize.width / 2
                        let originY = bgRect.midY - symbolSize.height / 2
                        ctx.setBlendMode(.destinationOut)
                        ctx.draw(symCG, in: CGRect(x: originX, y: originY,
                                                   width: symbolSize.width, height: symbolSize.height))
                        ctx.setBlendMode(.normal)
                    }
                }
            }
        }

        // 3. Colored status dot in top-right corner
        let dotSize: CGFloat = 6
        let dotRect = NSRect(x: size.width - dotSize - 1, y: size.height - dotSize - 1,
                             width: dotSize, height: dotSize)
        let dotPath = NSBezierPath(ovalIn: dotRect)
        dotColor(for: state).setFill()
        dotPath.fill()

        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = ctx.makeImage() else { return NSImage() }
        let result = NSImage(cgImage: cgImage, size: size)
        result.isTemplate = false
        result.accessibilityDescription = accessibilityLabel(for: state)
        return result
    }

    private static func dotColor(for state: VPNState) -> NSColor {
        switch state {
        case .connected:    return .systemGreen
        case .connecting:   return .systemOrange
        case .failed:       return .systemRed
        case .disconnected: return .systemGray
        }
    }

    private static func accessibilityLabel(for state: VPNState) -> String {
        switch state {
        case .connected:    return "VPN Connected"
        case .connecting:   return "VPN Connecting"
        case .failed:       return "VPN Failed"
        case .disconnected: return "VPN Disconnected"
        }
    }
}
