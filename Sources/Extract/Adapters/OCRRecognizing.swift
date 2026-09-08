import CoreGraphics
import Foundation

/// One OCR line in **oriented** page space (top-left origin, y down, normalised `0...1`).
struct RecognizedLine: Sendable, Equatable {
    var text: String
    var boundingBox: CGRect
    var confidence: Double
    /// Normalised x of each `Character` in ``text`` (Vision page space). Empty when unknown.
    var characterXs: [CGFloat]
}

protocol OCRRecognizing: Sendable {
    func recognize(image: CGImage) throws -> [RecognizedLine]
}
