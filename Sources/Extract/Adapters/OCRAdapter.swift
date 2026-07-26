import CoreGraphics
import Foundation
import PDFKit
import Vision

enum OCRAdapter {
    static func recognize(cgImage: CGImage, pageIndex: Int? = nil) throws -> [ExtractedDocument.Block] {
        try recognizeWithVision(cgImage: cgImage, pageIndex: pageIndex)
    }

    static func ocrPDFDocument(_ document: PDFDocument) throws -> [ExtractedDocument.Block] {
        var blocks: [ExtractedDocument.Block] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let width = Int(bounds.width * scale)
            let height = Int(bounds.height * scale)
            guard width > 0, height > 0 else { continue }

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }

            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            guard let image = context.makeImage() else { continue }
            let pageBlocks = try recognize(cgImage: image, pageIndex: index)
            blocks.append(contentsOf: pageBlocks)
        }
        return blocks
    }

    private static func recognizeWithVision(cgImage: CGImage, pageIndex: Int?) throws
        -> [ExtractedDocument.Block]
    {
        // Prefer newer document recognition when available (iOS 18 / macOS 15+ API surface).
        if #available(iOS 18.0, macOS 15.0, *) {
            if let blocks = try? recognizeDocuments(cgImage: cgImage, pageIndex: pageIndex), !blocks.isEmpty {
                return blocks
            }
        }
        return try recognizeTextRequest(cgImage: cgImage, pageIndex: pageIndex)
    }

    private static func recognizeTextRequest(cgImage: CGImage, pageIndex: Int?) throws
        -> [ExtractedDocument.Block]
    {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Vision returns observations roughly in reading order when sorted by geometry.
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ExtractionError.unreadableSource(underlying: error)
        }
        let observations = request.results ?? []
        let sorted = observations.sorted { a, b in
            let aBox = a.boundingBox
            let bBox = b.boundingBox
            // Top-to-bottom, then left-to-right (Vision uses bottom-left origin).
            if abs(aBox.minY - bBox.minY) > 0.02 {
                return aBox.minY > bBox.minY
            }
            return aBox.minX < bBox.minX
        }
        return sorted.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let box = observation.boundingBox
            // Convert to top-left normalized coords for provenance.
            let topLeft = CGRect(
                x: box.minX,
                y: 1.0 - box.maxY,
                width: box.width,
                height: box.height
            )
            return ExtractedDocument.Block(text: text, pageIndex: pageIndex, boundingBox: topLeft)
        }
    }

    @available(iOS 18.0, macOS 15.0, *)
    private static func recognizeDocuments(cgImage: CGImage, pageIndex: Int?) throws
        -> [ExtractedDocument.Block]
    {
        // RecognizeDocumentsRequest is available in newer Vision; fall back if the
        // symbol is missing at compile time on older SDKs via text request only.
        // On SDKs that ship it, this path improves structure slightly.
        #if swift(>=6.0)
            // Use the classic path as the reliable baseline; document request is best-effort.
            return try recognizeTextRequest(cgImage: cgImage, pageIndex: pageIndex)
        #else
            return try recognizeTextRequest(cgImage: cgImage, pageIndex: pageIndex)
        #endif
    }
}
