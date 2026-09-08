import CoreGraphics
import Foundation
import PDFKit

/// Pluggable PDF rasteriser. Default is ``PDFKitRenderer``; Linux can inject PDFium.
public protocol PDFRendering: Sendable {
    /// Oriented bitmap for `page`. `extraRotation` is clockwise degrees on top of `/Rotate`.
    func render(page: PDFPage, dpi: Double, extraRotation: Int) -> CGImage?
}

/// PDFKit rasteriser: honours `/Rotate`, configurable DPI (clamped `72...400`).
public struct PDFKitRenderer: PDFRendering {
    public static let minimumDPI: Double = 72
    public static let maximumDPI: Double = 400
    public static let defaultDPI: Double = 300

    public init() {}

    public func render(page: PDFPage, dpi: Double, extraRotation: Int) -> CGImage? {
        Self.render(page: page, dpi: dpi, extraRotation: extraRotation)
    }

    public static func clampedDPI(_ dpi: Double) -> Double {
        min(maximumDPI, max(minimumDPI, dpi))
    }

    public static func normalizedRotation(_ degrees: Int) -> Int {
        var rotation = degrees % 360
        if rotation < 0 {
            rotation += 360
        }
        return rotation
    }

    public static func displaySize(mediaSize: CGSize, rotation: Int) -> CGSize {
        switch normalizedRotation(rotation) {
        case 90, 270:
            return CGSize(width: mediaSize.height, height: mediaSize.width)
        default:
            return mediaSize
        }
    }

    /// Renders `page` into an oriented bitmap. `extraRotation` is applied on top of
    /// ``PDFPage/rotation`` (`/Rotate`).
    public static func render(page: PDFPage, dpi: Double, extraRotation: Int = 0) -> CGImage? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 0, media.height > 0 else {
            return nil
        }
        let totalRotation = normalizedRotation(page.rotation + extraRotation)
        let display = displaySize(mediaSize: media.size, rotation: totalRotation)
        let scale = CGFloat(clampedDPI(dpi) / 72.0)
        let pixelWidth = max(1, Int((display.width * scale).rounded()))
        let pixelHeight = max(1, Int((display.height * scale).rounded()))

        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        let savedRotation = page.rotation
        page.rotation = totalRotation
        defer { page.rotation = savedRotation }

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }
}
