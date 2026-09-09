import CoreGraphics
import Foundation
import PDFKit

enum OCRAdapter {
    /// - Parameter pageIndex: Defaults to `0` — a standalone image *is* page zero, which is
    ///   the convention ``FieldProvenance`` documents. It used to default to `nil`, and
    ///   because provenance requires both a box and a page, every image source silently had
    ///   no provenance at all despite Vision returning boxes for it.
    static func recognize(
        cgImage: CGImage,
        pageIndex: Int = 0,
        ocr: OCRRecognizing = VisionOCR()
    ) throws -> [ExtractedDocument.Block] {
        try blocks(from: ocr.recognize(image: cgImage), pageIndex: pageIndex)
    }

    static func ocrPDFPage(
        _ page: PDFPage,
        pageIndex: Int,
        options: ExtractionOptions,
        ocr: OCRRecognizing,
        renderer: PDFRendering
    ) throws -> [ExtractedDocument.Block] {
        let extraRotation: Int
        if options.autoOrient {
            extraRotation = detectOrientation(page: page, ocr: ocr, renderer: renderer)
        } else {
            extraRotation = 0
        }
        guard let image = renderer.render(page: page, dpi: options.rasterDPI, extraRotation: extraRotation)
        else {
            return []
        }
        return try blocks(from: ocr.recognize(image: image), pageIndex: pageIndex)
    }

    static func detectOrientation(
        page: PDFPage,
        ocr: OCRRecognizing,
        renderer: PDFRendering
    ) -> Int {
        let probeDPI = PDFKitRenderer.minimumDPI
        guard
            let upright = renderer.render(page: page, dpi: probeDPI, extraRotation: 0),
            let rotated = renderer.render(page: page, dpi: probeDPI, extraRotation: 90)
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
