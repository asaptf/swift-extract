import Foundation
import UniformTypeIdentifiers

enum SourceIngester {
    static func ingest(
        _ source: ExtractionSource,
        options: ExtractionOptions = .init(),
        engines: IngestContext = IngestContext()
    ) async throws -> ExtractedDocument {
        // Rasterisation and OCR block the calling thread. Run them off the cooperative
        // pool so concurrent extractions cannot starve it — see ``IngestExecutor``.
        try await IngestExecutor.run {
            try ingestSynchronously(source, options: options, engines: engines)
        }
    }

    private static func ingestSynchronously(
        _ source: ExtractionSource,
        options: ExtractionOptions,
        engines: IngestContext
    ) throws -> ExtractedDocument {
        do {
            switch source {
            case .text(let string):
                return TextAdapter.ingest(string)
            case .pdf(let url):
                return try PDFAdapter.ingest(url: url, options: options, engines: engines)
            case .image(let cgImage):
                let blocks = try OCRAdapter.recognize(cgImage: cgImage, options: options, ocr: engines.ocr)
                return ExtractedDocument(blocks: blocks, sourceDescription: "image")
            case .fileURL(let url):
                return try ingestFile(url: url, options: options, engines: engines)
            }
        } catch let error as ExtractionError {
            throw error
        } catch {
            throw ExtractionError.unreadableSource(underlying: error)
        }
    }

    private static func ingestFile(
        url: URL,
        options: ExtractionOptions,
        engines: IngestContext
    ) throws -> ExtractedDocument {
        let values = try url.resourceValues(forKeys: [.contentTypeKey])
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)

        if let type {
            if type.conforms(to: .pdf) {
                return try PDFAdapter.ingest(url: url, options: options, engines: engines)
            }
            if type.conforms(to: .image) {
                let data = try Data(contentsOf: url)
                guard let cgImage = CGImageLoader.cgImage(from: data) else {
                    throw ExtractionError.unreadableSource(underlying: nil)
                }
                let blocks = try OCRAdapter.recognize(cgImage: cgImage, options: options, ocr: engines.ocr)
                return ExtractedDocument(blocks: blocks, sourceDescription: url.lastPathComponent)
            }
            if type.conforms(to: .text) || type.conforms(to: .plainText) || type.conforms(to: .utf8PlainText) {
                let text = try String(contentsOf: url, encoding: .utf8)
                return TextAdapter.ingest(text)
            }
        }

        // Extension fallback
        switch url.pathExtension.lowercased() {
        case "pdf":
            return try PDFAdapter.ingest(url: url, options: options, engines: engines)
        case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp":
            let data = try Data(contentsOf: url)
            guard let cgImage = CGImageLoader.cgImage(from: data) else {
                throw ExtractionError.unreadableSource(underlying: nil)
            }
            let blocks = try OCRAdapter.recognize(cgImage: cgImage, options: options, ocr: engines.ocr)
            return ExtractedDocument(blocks: blocks, sourceDescription: url.lastPathComponent)
        case "txt", "md", "csv", "json", "html", "xml":
            let text = try String(contentsOf: url, encoding: .utf8)
            return TextAdapter.ingest(text)
        default:
            // Last resort: try text, then image, then PDF
            if let text = try? String(contentsOf: url, encoding: .utf8),
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return TextAdapter.ingest(text)
            }
            throw ExtractionError.unreadableSource(
                underlying: NSError(
                    domain: "Extract",
                    code: 3,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unsupported file type for \(url.lastPathComponent)"
                    ]
                )
            )
        }
    }
}
