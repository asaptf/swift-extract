import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

@testable import Extract

/// Test-only / harness-side helper: draw normalised top-left field boxes on a page image
/// and write a PNG. **Not** part of the public Extract API — the library returns geometry
/// only and does not render.
enum ProvenanceDebugRenderer {
    struct Overlay {
        var path: String
        var pageIndex: Int
        var boundingBox: CGRect
        var label: String?
    }

    /// Render `overlays` for `pageIndex` onto `pageImage` (top-left pixel origin) and write PNG.
    static func writePNG(
        pageImage: CGImage,
        pageIndex: Int,
        overlays: [Overlay],
        to url: URL
    ) throws {
        let width = pageImage.width
        let height = pageImage.height
        guard width > 0, height > 0 else {
            throw ExtractionError.internalError("empty page image")
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw ExtractionError.internalError("could not create bitmap context")
        }

        // CGContext origin is bottom-left. Draw the page image upright, then convert
        // top-left normalised boxes into that space.
        ctx.draw(pageImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let pageOverlays = overlays.filter { $0.pageIndex == pageIndex }
        let w = CGFloat(width)
        let h = CGFloat(height)

        ctx.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.1, alpha: 0.95))
        ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.18))
        ctx.setLineWidth(max(2, min(w, h) * 0.004))

        for overlay in pageOverlays {
            let box = overlay.boundingBox
            // FieldProvenance: top-left origin, y down, normalised → CG bottom-left points.
            let rect = CGRect(
                x: box.minX * w,
                y: (1.0 - box.maxY) * h,
                width: box.width * w,
                height: box.height * h
            )
            ctx.fill(rect)
            ctx.stroke(rect)
        }

        guard let outImage = ctx.makeImage() else {
            throw ExtractionError.internalError("could not snapshot overlay image")
        }
        try writeCGImagePNG(outImage, to: url)
    }

    /// Rasterise PDF page `pageIndex` (0-based) at `scale`.
    ///
    /// Uses `PDFPage.thumbnail` so the page is upright in top-left image space,
    /// matching ``FieldProvenance`` (top-left origin, y down).
    static func renderPDFPage(url: URL, pageIndex: Int, scale: CGFloat = 2.0) throws -> CGImage {
        guard let document = PDFDocument(url: url),
            let page = document.page(at: pageIndex)
        else {
            throw ExtractionError.unreadableSource(
                underlying: NSError(
                    domain: "ProvenanceDebug",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not open PDF page \(pageIndex)"]
                )
            )
        }
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else {
            throw ExtractionError.internalError("invalid PDF page size")
        }
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: size)
        guard let image = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else {
            throw ExtractionError.internalError("PDF page thumbnail produced no CGImage")
        }
        return image
    }

    static func loadImage(url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url)
        guard let image = CGImageLoader.cgImage(from: data) else {
            throw ExtractionError.unreadableSource(
                underlying: NSError(
                    domain: "ProvenanceDebug",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not decode image at \(url.path)"]
                )
            )
        }
        return image
    }

    private static func writeCGImagePNG(_ image: CGImage, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw ExtractionError.internalError("CGImageDestination failed for \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ExtractionError.internalError("failed to write PNG \(url.path)")
        }
    }
}
