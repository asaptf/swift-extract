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
    public static func image(data: Data) throws -> ExtractionSource {
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
    static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
