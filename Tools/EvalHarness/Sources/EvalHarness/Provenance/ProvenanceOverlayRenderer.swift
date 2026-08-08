import CoreGraphics
import Extract
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Debug-only: draw normalised top-left field boxes on a page raster and write a PNG.
///
/// Not part of the Extract public API. The library returns geometry; this harness
/// helper exists so humans can verify boxes sit on the right lines.
public enum ProvenanceOverlayRenderer {
    public struct Overlay: Sendable {
        public var path: String
        public var pageIndex: Int
        public var boundingBox: CGRect

        public init(path: String, pageIndex: Int, boundingBox: CGRect) {
            self.path = path
            self.pageIndex = pageIndex
            self.boundingBox = boundingBox
        }
    }

    /// Build overlays from extraction signals that carry provenance.
    public static func overlays(from signals: ExtractionSignals) -> [Overlay] {
        signals.fields.compactMap { field in
            guard let prov = field.provenance else { return nil }
            return Overlay(
                path: field.path,
                pageIndex: prov.pageIndex,
                boundingBox: prov.boundingBox
            )
        }
    }

    public static func writePNG(
        pageImage: CGImage,
        pageIndex: Int,
        overlays: [Overlay],
        to url: URL
    ) throws {
        let width = pageImage.width
        let height = pageImage.height
        guard width > 0, height > 0 else {
            throw RenderError.emptyImage
        }
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw RenderError.contextFailed
        }

        ctx.draw(pageImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let w = CGFloat(width)
        let h = CGFloat(height)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.15, blue: 0.1, alpha: 0.95))
        ctx.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.18))
        ctx.setLineWidth(max(2, min(w, h) * 0.004))

        for overlay in overlays where overlay.pageIndex == pageIndex {
            let box = overlay.boundingBox
            // FieldProvenance: top-left, y down, normalised → CG bottom-left.
            let rect = CGRect(
                x: box.minX * w,
                y: (1.0 - box.maxY) * h,
                width: box.width * w,
                height: box.height * h
            )
            ctx.fill(rect)
            ctx.stroke(rect)
        }

        guard let out = ctx.makeImage() else { throw RenderError.snapshotFailed }
        try writePNG(out, to: url)
    }

    /// Rasterise a PDF page upright (top-left image space), matching ``FieldProvenance``.
    public static func renderPDFPage(url: URL, pageIndex: Int, scale: CGFloat = 2.0) throws -> CGImage {
        guard let document = PDFDocument(url: url), let page = document.page(at: pageIndex) else {
            throw RenderError.unreadablePDF
        }
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { throw RenderError.emptyImage }
        let thumbnail = page.thumbnail(of: size, for: .mediaBox)
        var proposed = CGRect(origin: .zero, size: size)
        guard let image = thumbnail.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else {
            throw RenderError.snapshotFailed
        }
        return image
    }

    public enum RenderError: Error, CustomStringConvertible {
        case emptyImage
        case contextFailed
        case snapshotFailed
        case unreadablePDF
        case writeFailed(String)

        public var description: String {
            switch self {
            case .emptyImage: return "empty page image"
            case .contextFailed: return "could not create graphics context"
            case .snapshotFailed: return "could not snapshot image"
            case .unreadablePDF: return "could not open PDF page"
            case .writeFailed(let path): return "failed to write PNG at \(path)"
            }
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw RenderError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw RenderError.writeFailed(url.path)
        }
    }
}
