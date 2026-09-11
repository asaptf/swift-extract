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

    /// - Parameter rotation: the turn already decided for this page — by
    ///   ``OrientationDetector/resolve(_:)`` across the whole document, which knows things one
    ///   page cannot. `nil` decides it from this page alone.
    static func ocrPDFPage(
        _ page: PDFPage,
        pageIndex: Int,
        options: ExtractionOptions,
        ocr: OCRRecognizing,
        renderer: PDFRendering,
        rotation: Int? = nil
    ) throws -> [ExtractedDocument.Block] {
        let extraRotation: Int
        if let rotation {
            extraRotation = options.autoOrient ? rotation : 0
        } else if options.autoOrient {
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

    /// Renders and reads **every** quarter turn at the probe DPI, then takes the one that
    /// reads best. Four cheap probes instead of two, which is what it costs to stop guessing:
    /// a page can fall either way, the two ends of an axis are the same text upside-down, and
    /// no indirect signal separates them (see ``OrientationDetector``).
    static func detectOrientation(
        page: PDFPage,
        ocr: OCRRecognizing,
        renderer: PDFRendering
    ) -> Int {
        orientation(page: page, ocr: ocr, renderer: renderer).rotation
    }

    static func orientation(
        page: PDFPage,
        ocr: OCRRecognizing,
        renderer: PDFRendering
    ) -> OrientationDecision {
        let probeDPI = PDFKitRenderer.minimumDPI
        var scores: [Int: Double] = [:]
        for rotation in [0, 90, 180, 270] {
            guard let image = renderer.render(page: page, dpi: probeDPI, extraRotation: rotation)
            else { continue }
            scores[rotation] = OrientationDetector.axisScore((try? ocr.recognize(image: image)) ?? [])
        }
        return OrientationDetector.choose(scores: scores)
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
