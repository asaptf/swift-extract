import Foundation

/// OCR and PDF engines used during ingest. Defaults are Vision and PDFKit.
///
/// Pass a custom context to ``Extract/from(_:using:options:ingest:)`` or
/// ``Extract/inspect(_:tableDetection:options:ingest:)`` to inject another
/// engine (tests, or Tesseract/PDFium on Linux later).
public struct IngestContext: Sendable {
    public var ocr: any OCRRecognizing
    public var renderer: any PDFRendering

    public init(
        ocr: any OCRRecognizing = VisionOCR(),
        renderer: any PDFRendering = PDFKitRenderer()
    ) {
        self.ocr = ocr
        self.renderer = renderer
    }
}
