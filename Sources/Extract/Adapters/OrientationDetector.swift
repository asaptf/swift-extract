import CoreGraphics
import Foundation

/// What a quarter-turn probe concluded about a page.
struct OrientationDecision: Equatable, Sendable {
    /// Extra clockwise rotation in `{0, 90, 180, 270}`, on top of PDF `/Rotate`.
    var rotation: Int
    /// How much better the chosen turn read than leaving the page alone. `1` means the probe
    /// saw no reason to turn it; a page is left alone unless this clears ``decisiveGain``.
    var gain: Double
    /// How much better the chosen turn read than the same page upside-down. Near `1` means
    /// the probe could not tell the two apart — the text reads either way — and the direction
    /// is a coin toss that must not be presented as a finding.
    var margin: Double

    /// True when the axis is clear but the direction along it is not.
    var isAmbiguous: Bool { margin < OrientationDetector.decisiveMargin }
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
    /// How much better the chosen turn must read than its opposite before the direction counts
    /// as known. Measured: on a real scan the upright turn scored 3.7× to 4.7× the upside-down
    /// one, while on clean synthetic print the two came within 1% — the same text, read either
    /// way round. Below this the page's own probe decides nothing.
    static let decisiveMargin = 1.2

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
            return OrientationDecision(rotation: 0, gain: 1, margin: .infinity)
        }
        let opposite = scores[(best.key + 180) % 360] ?? 0
        let margin = opposite > 0 ? best.value / opposite : Double.infinity
        if best.key == 0 {
            return OrientationDecision(rotation: 0, gain: 1, margin: margin)
        }
        let gain = identity > 0 ? best.value / identity : Double.infinity
        if gain < decisiveGain {
            return OrientationDecision(rotation: 0, gain: gain, margin: margin)
        }
        return OrientationDecision(rotation: best.key, gain: gain, margin: margin)
    }

    /// Settles pages the probe could not settle on its own.
    ///
    /// A stack of sheets goes through a scanner the same way round, so a page whose direction
    /// is a coin toss takes it from the pages that were sure — but only from pages lying on
    /// the **same axis**: that page one is upright says nothing about which way page three
    /// fell. A page with no confident peer keeps its own best guess, still marked ambiguous,
    /// because inventing agreement would hide exactly the case a caller needs to see.
    static func resolve(_ decisions: [Int: OrientationDecision]) -> [Int: OrientationDecision] {
        var votes: [Int: Int] = [:]
        for decision in decisions.values where !decision.isAmbiguous {
            votes[decision.rotation, default: 0] += 1
        }
        return decisions.mapValues { decision in
            guard decision.isAmbiguous else { return decision }
            let sameAxis = votes.filter { $0.key % 180 == decision.rotation % 180 }
            guard let winner = sameAxis.max(by: { $0.value < $1.value })?.key else { return decision }
            var resolved = decision
            resolved.rotation = winner
            return resolved
        }
    }
}
