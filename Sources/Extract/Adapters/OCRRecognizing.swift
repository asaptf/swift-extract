import CoreGraphics
import Foundation
import Vision

/// One OCR line in **oriented** page space (top-left origin, y down, normalised `0...1`).
///
/// ``characterXs`` are the normalised x-centres of each `Character` in ``text``, used
/// for 180° disambiguation. Empty when the engine cannot supply them.
public struct RecognizedLine: Sendable, Equatable {
    public var text: String
    public var boundingBox: CGRect
    public var confidence: Double
    public var characterXs: [CGFloat]

    public init(
        text: String,
        boundingBox: CGRect,
        confidence: Double,
        characterXs: [CGFloat] = []
    ) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.characterXs = characterXs
    }
}

/// Pluggable OCR engine. Default is ``VisionOCR``; Linux can inject Tesseract/RapidOCR.
public protocol OCRRecognizing: Sendable {
    func recognize(image: CGImage) throws -> [RecognizedLine]
}

/// Vision `VNRecognizeTextRequest` (`.accurate`) with per-character boxes when available.
public struct VisionOCR: OCRRecognizing {
    public init() {}

    public func recognize(image: CGImage) throws -> [RecognizedLine] {
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
