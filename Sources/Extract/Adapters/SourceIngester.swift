import Foundation
import ImageIO
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
            case .page(let text, let images):
                var document = TextAdapter.ingest(text)
                document.pageImages = images
                return document
            case .pdf(let url):
                return try PDFAdapter.ingest(url: url, options: options, engines: engines)
            case .image(let cgImage):
                let blocks = try OCRAdapter.recognize(cgImage: cgImage, options: options, ocr: engines.ocr)
                return ExtractedDocument(
                    blocks: blocks, sourceDescription: "image",
                    pageSources: blocks.isEmpty ? [:] : [0: .ocr])
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
                return try ingestImage(
                    data: Data(contentsOf: url), sourceDescription: url.lastPathComponent, options: options,
                    engines: engines)
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
            return try ingestImage(
                data: Data(contentsOf: url), sourceDescription: url.lastPathComponent, options: options,
                engines: engines)
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

    /// Every frame of an image file, each read as a page of its own: page `n` is frame `n`.
    ///
    /// A fax, a scanner's multi-page TIFF and an animated GIF are several pictures in one file,
    /// and reading only the first handed back a document pages short with nothing to say so. A
    /// frame is read as it is stored — never turned, like any picture — and one that yields no
    /// text is absent from the page sources, as a blank PDF page is. A frame that cannot be
    /// decoded fails the file rather than leaving a hole in it.
    private static func ingestImage(
        data: Data,
        sourceDescription: String,
        options: ExtractionOptions,
        engines: IngestContext
    ) throws -> ExtractedDocument {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ExtractionError.unreadableSource(underlying: nil)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw ExtractionError.unreadableSource(underlying: nil) }
        var blocks: [ExtractedDocument.Block] = []
        var sources: [Int: PageTextSource] = [:]
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw ExtractionError.unreadableSource(underlying: nil)
            }
            let read = try OCRAdapter.recognize(cgImage: frame, pageIndex: index, options: options, ocr: engines.ocr)
            if !read.isEmpty {
                blocks.append(contentsOf: read)
                sources[index] = .ocr
            }
        }
        return ExtractedDocument(blocks: blocks, sourceDescription: sourceDescription, pageSources: sources)
    }
}
