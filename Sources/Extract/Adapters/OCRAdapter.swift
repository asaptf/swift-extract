import CoreGraphics
import Foundation
import PDFKit
import Vision

enum OCRAdapter {
    static func recognize(cgImage: CGImage, pageIndex: Int? = nil) throws -> [ExtractedDocument.Block] {
        try blocks(from: VisionOCR().recognize(image: cgImage), pageIndex: pageIndex)
    }

    static func ocrPDFPage(
        _ page: PDFPage,
        pageIndex: Int,
        options: ExtractionOptions,
        ocr: OCRRecognizing
    ) throws -> [ExtractedDocument.Block] {
        let extraRotation: Int
        if options.autoOrient {
            extraRotation = detectOrientation(page: page, ocr: ocr)
        } else {
            extraRotation = 0
        }
        guard
            let image = PDFPageRenderer.render(
                page: page,
                dpi: options.rasterDPI,
                extraRotation: extraRotation
            )
        else {
            return []
        }
        return try blocks(from: ocr.recognize(image: image), pageIndex: pageIndex)
    }

    static func detectOrientation(page: PDFPage, ocr: OCRRecognizing) -> Int {
        let probeDPI = PDFPageRenderer.minimumDPI
        guard
            let upright = PDFPageRenderer.render(page: page, dpi: probeDPI, extraRotation: 0),
            let rotated = PDFPageRenderer.render(page: page, dpi: probeDPI, extraRotation: 90)
        else {
            return 0
        }
        let lines0 = (try? ocr.recognize(image: upright)) ?? []
        let lines90 = (try? ocr.recognize(image: rotated)) ?? []
        return OrientationDetector.choose(upright: lines0, rotated90: lines90)
    }

    static func blocks(from lines: [RecognizedLine], pageIndex: Int?) -> [ExtractedDocument.Block] {
        lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ExtractedDocument.Block(
                text: text,
                pageIndex: pageIndex,
                boundingBox: line.boundingBox
            )
        }
    }
}

struct VisionOCR: OCRRecognizing {
    func recognize(image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ExtractionError.unreadableSource(underlying: error)
        }
        let observations = request.results ?? []
        let sorted = observations.sorted { a, b in
            let aBox = a.boundingBox
            let bBox = b.boundingBox
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
            let topLeft = CGRect(
                x: box.minX,
                y: 1.0 - box.maxY,
                width: box.width,
                height: box.height
            )
            return RecognizedLine(
                text: text,
                boundingBox: topLeft,
                confidence: Double(candidate.confidence),
                characterXs: characterXs(in: candidate, text: candidate.string)
            )
        }
    }

    private func characterXs(in candidate: VNRecognizedText, text: String) -> [CGFloat] {
        var xs: [CGFloat] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if let box = try? candidate.boundingBox(for: index..<next) {
                xs.append(box.boundingBox.midX)
            } else if let last = xs.last {
                xs.append(last)
            }
            index = next
        }
        return xs
    }
}
