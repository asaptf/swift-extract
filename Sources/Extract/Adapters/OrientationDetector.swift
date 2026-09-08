import CoreGraphics
import Foundation

/// Chooses an extra rotation (beyond PDF `/Rotate`) so OCR text is upright.
///
/// Axis (0° vs 90°) is scored from line geometry: character count × confidence ×
/// wide-and-short bonus. 180° / 270° use per-character x-order on long lines
/// (Vision reads upside-down text at the same confidence).
enum OrientationDetector {
    static func axisScore(_ lines: [RecognizedLine]) -> Double {
        var score = 0.0
        for line in lines {
            let wide = line.boundingBox.width > line.boundingBox.height
            let aspectBonus = wide ? 1.0 : 0.1
            score += Double(line.text.count) * max(line.confidence, 0) * aspectBonus
        }
        return score
    }

    /// Positive → left-to-right (upright); negative → right-to-left (upside-down).
    static func readingDirection(_ lines: [RecognizedLine]) -> Double {
        let ranked = lines.sorted { $0.text.count > $1.text.count }.prefix(5)
        var total = 0.0
        for line in ranked {
            guard line.characterXs.count >= 4 else { continue }
            let head = line.characterXs.prefix(3).reduce(0, +) / 3
            let tail = line.characterXs.suffix(3).reduce(0, +) / 3
            total += Double(tail - head) * Double(line.text.count)
        }
        return total
    }

    /// Extra clockwise rotation in `{0, 90, 180, 270}`.
    static func choose(upright: [RecognizedLine], rotated90: [RecognizedLine]) -> Int {
        let score0 = axisScore(upright)
        let score90 = axisScore(rotated90)
        if score0 == 0, score90 == 0 {
            return 0
        }
        if score90 > score0 {
            return readingDirection(rotated90) < 0 ? 270 : 90
        }
        return readingDirection(upright) < 0 ? 180 : 0
    }
}
