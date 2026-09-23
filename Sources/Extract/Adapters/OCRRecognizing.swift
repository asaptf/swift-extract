import CoreGraphics
import Foundation
import Vision

/// One OCR line in **oriented** page space (top-left origin, y down, normalised `0...1`).
///
/// ``characterXs`` are the normalised x-centres of each `Character` in ``text``, which say
/// which way up the line was read (``orientation``). Empty when the engine cannot supply them.
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

extension RecognizedLine {
    /// How far apart the first and last words must sit, as a share of the line's width, before
    /// their order counts. The centres of a line's first and last words are at least a quarter
    /// of its width apart; words reported at one centre, or a hair apart, are one word or noise.
    static let decisiveSpread: CGFloat = 0.25

    /// Which way up this line stood in the image it was read from, told from where its first
    /// and last words are — see ``LineOrientation``.
    ///
    /// Measured on macOS 27, whose Vision reports a box per word for any character range inside
    /// it and a space at x = 0. On the six pages of the customer's scanned invoice at 300 DPI,
    /// every line with an order came out upright at the upright turn and upside down at its
    /// opposite — 25 to 47 lines a page, none the other way. At the 72 DPI probe the upright
    /// turn is as clean; its opposite misreads a few short lines as upright, 38 characters
    /// against 450 on the worst page. Spaces are left out, and so are lines lying down the page,
    /// whose words share an x-centre give or take noise.
    var orientation: LineOrientation {
        guard boundingBox.width > boundingBox.height, characterXs.count == text.count else { return .unknown }
        let xs = zip(text, characterXs).filter { !$0.0.isWhitespace }.map(\.1)
        guard let first = xs.first, let last = xs.last,
            abs(last - first) >= Self.decisiveSpread * boundingBox.width
        else { return .unknown }
        let runsAsWritten = Self.isWrittenRightToLeft(text) ? last < first : last > first
        return runsAsWritten ? .upright : .upsideDown
    }

    /// Whether the line's script runs right to left, by its first letter — the rule Unicode sets
    /// a paragraph's direction by, and the one CoreText lays a line by. Figures have no direction
    /// of their own, so a line of figures runs left to right.
    static func isWrittenRightToLeft(_ text: String) -> Bool {
        guard let letter = text.unicodeScalars.first(where: \.properties.isAlphabetic) else { return false }
        return rightToLeftScalars.contains { $0.contains(letter.value) }
    }

    /// Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan and Mandaic with their extensions, the
    /// Hebrew and Arabic presentation forms, and the right-to-left blocks beyond the BMP. Checked
    /// against Unicode 16.0: every letter in these ranges has bidi class R or AL — Cypriot and
    /// Old Turkic included — and no letter outside them does.
    private static let rightToLeftScalars: [ClosedRange<UInt32>] = [
        0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF,
    ]
}

/// Pluggable OCR engine. Default is ``VisionOCR``; Linux can inject Tesseract/RapidOCR.
public protocol OCRRecognizing: Sendable {
    func recognize(image: CGImage) throws -> [RecognizedLine]

    /// Reads a page that may be printed in the given scripts.
    ///
    /// The default implementation ignores both arguments and reads the way the engine always
    /// does, so an engine written before this existed keeps working — but an engine that
    /// cannot honour the request will read a page in the wrong script the way Vision does:
    /// approximately, and without saying so.
    func recognize(
        image: CGImage, languages: [String], correctsLanguage: Bool
    ) throws -> [RecognizedLine]
}

extension OCRRecognizing {
    public func recognize(
        image: CGImage, languages: [String], correctsLanguage: Bool
    ) throws -> [RecognizedLine] {
        try recognize(image: image)
    }
}

/// Vision `VNRecognizeTextRequest` (`.accurate`) with per-character boxes when available.
public struct VisionOCR: OCRRecognizing {
    public init() {}

    public func recognize(image: CGImage) throws -> [RecognizedLine] {
        try recognize(image: image, languages: [], correctsLanguage: true)
    }

    public func recognize(
        image: CGImage, languages: [String], correctsLanguage: Bool
    ) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        // `.accurate` is not only about quality: the fast path supports six European
        // languages and nothing else, so Arabic exists only on this one.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correctsLanguage
        if languages.isEmpty {
            // Saying nothing used to mean English, silently, and an Arabic page came back
            // as confident Latin nonsense with no signal that a script had been missed.
            // Saying nothing now means look: Vision's own detection reads that page
            // correctly — measured, 195 Arabic characters against none.
            //
            // It is not free, which is why it is the fallback and not the rule. A detector
            // weighs every script it supports, so on dense small print a smudge can become
            // a character from a script the page does not contain: on one scanned invoice
            // it read the article number 644610 as 544610 and produced fragments of CJK.
            // A caller that knows the script should say so and get exactly that script.
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
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
