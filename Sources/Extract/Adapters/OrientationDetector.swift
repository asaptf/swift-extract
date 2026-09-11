import CoreGraphics
import Foundation

/// What a quarter-turn probe concluded about a page.
struct OrientationDecision: Equatable, Sendable {
    /// Extra clockwise rotation in `{0, 90, 180, 270}`, on top of PDF `/Rotate`.
    var rotation: Int
    /// How much better the chosen turn read than leaving the page alone. `1` means the probe
    /// saw no reason to turn it; a page is left alone unless this clears ``decisiveGain``.
    var gain: Double
}

/// Chooses an extra rotation (beyond PDF `/Rotate`) so OCR text is upright.
///
/// Each candidate turn is **rendered and read**, and the one whose recognition looks most
/// like running text wins. There is deliberately no cleverness about which direction a page
/// fell: on a scan of dense small print Vision reads the page nearly as well upside-down as
/// upright, so every indirect signal — character x-order, mean confidence, edge alignment —
/// was measured on a six-page customer invoice and none of them separated 90° from 270°.
/// Scoring the turn you are about to take is the only signal that did: the upright quarter
/// turn scored about four times the upside-down one on every sideways page.
enum OrientationDetector {
    /// A page that already reads is left alone unless a turn reads clearly better. Measured
    /// counter-example: a nearly blank last page scored 234 upright and 297 upside-down —
    /// noise, not evidence, and turning it would have been wrong.
    static let decisiveGain = 1.5

    static func axisScore(_ lines: [RecognizedLine]) -> Double {
        var score = 0.0
        for line in lines {
            let wide = line.boundingBox.width > line.boundingBox.height
            let aspectBonus = wide ? 1.0 : 0.1
            score += Double(line.text.count) * max(line.confidence, 0) * aspectBonus
        }
        return score
    }

    /// - Parameter scores: recognition score per candidate clockwise turn. `0` must be present;
    ///   turns that were never rendered are simply absent.
    static func choose(scores: [Int: Double]) -> OrientationDecision {
        let identity = max(scores[0] ?? 0, 0)
        guard let best = scores.max(by: { $0.value < $1.value }), best.value > 0 else {
            return OrientationDecision(rotation: 0, gain: 1)
        }
        if best.key == 0 {
            return OrientationDecision(rotation: 0, gain: 1)
        }
        let gain = identity > 0 ? best.value / identity : Double.infinity
        if gain < decisiveGain {
            return OrientationDecision(rotation: 0, gain: gain)
        }
        return OrientationDecision(rotation: best.key, gain: gain)
    }
}
