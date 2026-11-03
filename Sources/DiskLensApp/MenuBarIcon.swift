import AppKit

/// The menu bar symbol: the app icon's lens over its three tiles, as a template
/// image so macOS tints it for light and dark menu bars.
@MainActor
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for scale in [1, 2, 3] {
            image.addRepresentation(bitmap(scale: scale))
        }
        image.isTemplate = true
        return image
    }()

    private static func bitmap(scale: Int) -> NSBitmapImageRep {
        let pixels = 18 * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        // The context is in pixels with y going up; draw in points with y going down.
        let transform = NSAffineTransform()
        transform.translateX(by: 0, yBy: CGFloat(pixels))
        transform.scaleX(by: CGFloat(scale), yBy: -CGFloat(scale))
        transform.concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 18, height: 18)
        return bitmap
    }

    private static func draw() {
        NSColor.black.set()

        let ring = NSBezierPath(ovalIn: NSRect(x: 1.25, y: 1.25, width: 12.5, height: 12.5))
        ring.lineWidth = 1.5
        ring.stroke()

        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: 12.2, y: 12.2))
        handle.line(to: NSPoint(x: 16.1, y: 16.1))
        handle.lineWidth = 2.2
        handle.lineCapStyle = .round
        handle.stroke()

        NSBezierPath(ovalIn: NSRect(x: 2.9, y: 2.9, width: 9.2, height: 9.2)).addClip()
        NSRect(x: 2.9, y: 2.9, width: 4.1, height: 9.2).fill()
        NSRect(x: 7.9, y: 2.9, width: 4.2, height: 4.2).fill()
        NSRect(x: 7.9, y: 8, width: 4.2, height: 4.1).fill()
    }
}
