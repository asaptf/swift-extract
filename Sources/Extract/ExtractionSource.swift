import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    import AppKit
#endif

/// Input adapters for extraction.
public enum ExtractionSource: Sendable {
    case text(String)
    /// One page, given as both its text and its picture.
    ///
    /// The text is what grounding and provenance are computed from — a box on the page is what
    /// lets an operator see where a value came from — while the picture is what the model
    /// reads. A vision model given the page does not inherit the mistakes OCR already made.
    case page(text: String, images: [PageImage])
    case pdf(URL)
    case image(CGImage)
    /// Sniffs the file type via UTType and routes to the appropriate adapter.
    case fileURL(URL)
}

extension ExtractionSource {
    /// Convenience: treat a bare string as text.
    public static func string(_ value: String) -> ExtractionSource { .text(value) }
}

// MARK: - Platform image conveniences

extension ExtractionSource {
    /// One picture, decoded from the bytes of an image file.
    ///
    /// Throws for a file of several frames — a fax, a scanner's multi-page TIFF, an animated
    /// GIF. A picture is one page, and keeping the first frame would drop the rest without a
    /// word; ``fileURL(_:)`` reads every frame as a page of its own.
    public static func image(data: Data) throws -> ExtractionSource {
        let frames = CGImageLoader.frameCount(of: data)
        guard frames <= 1 else {
            throw ExtractionError.unreadableSource(
                underlying: NSError(
                    domain: "Extract",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "The image has \(frames) frames and a picture is one page; "
                            + "read the file with ExtractionSource.fileURL, which reads every frame as a page"
                    ]
                )
            )
        }
        guard let cgImage = CGImageLoader.cgImage(from: data) else {
            throw ExtractionError.unreadableSource(
                underlying: NSError(
                    domain: "Extract",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not decode image data"]
                )
            )
        }
        return .image(cgImage)
    }

    /// One picture, decoded from an image file; see ``image(data:)``.
    public static func image(url: URL) throws -> ExtractionSource {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ExtractionError.unreadableSource(underlying: error)
        }
        return try image(data: data)
    }

    #if canImport(UIKit)
        public static func image(_ uiImage: UIImage) throws -> ExtractionSource {
            guard let cgImage = uiImage.cgImage else {
                // Try redrawing
                let format = UIGraphicsImageRendererFormat.default()
                format.scale = uiImage.scale
                let renderer = UIGraphicsImageRenderer(size: uiImage.size, format: format)
                let rendered = renderer.image { _ in
                    uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
                }
                guard let cg = rendered.cgImage else {
                    throw ExtractionError.unreadableSource(underlying: nil)
                }
                return .image(cg)
            }
            return .image(cgImage)
        }
    #endif

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        public static func image(_ nsImage: NSImage) throws -> ExtractionSource {
            var rect = CGRect(origin: .zero, size: nsImage.size)
            guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                throw ExtractionError.unreadableSource(underlying: nil)
            }
            return .image(cgImage)
        }
    #endif
}

enum CGImageLoader {
    /// The first frame — the whole of an image of one.
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// How many pictures the file holds: one for almost every image, one per page for a fax or a
    /// multi-page TIFF, one per frame for an animated GIF. A photo's HDR gain map is not a frame.
    static func frameCount(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }
}
