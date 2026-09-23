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
    /// True when the order of the words along the page's lines settled a direction the scores
    /// left a coin toss; see ``OrientationDetector/choose(readings:)``.
    var settledByLineOrder = false

    /// True when the axis is clear but the direction along it is not.
    var isAmbiguous: Bool { margin < OrientationDetector.decisiveMargin && !settledByLineOrder }
}

/// Chooses an extra rotation (beyond PDF `/Rotate`) so OCR text is upright.
///
/// Each candidate turn is **rendered and read**, and the one whose recognition looks most
/// like running text wins. On a scan of dense small print Vision reads the page nearly as well
/// upside-down as upright, and when this was built three indirect signals — character x-order,
/// mean confidence, edge alignment — were measured on a six-page customer invoice and none of
/// them separated 90° from 270°. Scoring the turn you are about to take did: the upright
/// quarter turn scored about four times the upside-down one on every sideways page.
///
/// The score is still what decides. Where it cannot — clean print reads within 1% either way
/// up — the order of the words along each line settles the direction (``choose(readings:)``).
/// Re-measured on macOS 27, which reports a box per word: once spaces and lines lying down the
/// page are left out, word order separates the two ends of the axis on every page of that
/// invoice, including one whose two readings scored within 22% of each other.
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
    /// How much more of the page's text has to stand upright one way than the other before the
    /// lines settle a direction. Measured on the customer's invoice at the probe DPI: the upright
    /// turn out-witnessed its opposite 11.8 times on the worst page, 450 characters against 38
    /// that the upside-down probe misread as upright; on clean print no line dissents at all.
    static let decisiveLineOrder = 3.0
    /// Fewest witnesses a settled direction needs. A line witnesses once for each probe that read
    /// it with an order, so a page with one legible line — a heading, a stamp — cannot settle one.
    static let minimumLineOrderWitnesses = 3

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

    /// Chooses a turn from what each probe read: by the scores, and — only where they leave the
    /// direction a coin toss — by which way the words run.
    ///
    /// The two ends of an axis are the same text half a turn apart, and on clean print Vision
    /// reads both. What differs is the order: read the right way up, a line's words run the way
    /// its script is written; read upside down, they run backwards (``RecognizedLine/orientation``).
    /// Each probe is a witness: lines upright at a turn speak for it, and lines upside down at
    /// its opposite speak for it too.
    ///
    /// A direction the scores settle is kept as it is, whatever the lines say. On the customer's
    /// invoice the two agree on every page, and extraction accuracy was measured on those turns.
    /// - Parameter readings: what OCR read at each candidate clockwise turn. `0` must be present.
    static func choose(readings: [Int: [RecognizedLine]]) -> OrientationDecision {
        let scores = readings.mapValues(axisScore)
        var decision = choose(scores: scores)
        guard decision.isAmbiguous else { return decision }
        let turn = decision.rotation
        let opposite = (turn + 180) % 360
        let forTurn = witnesses(standingUprightAt: turn, in: readings)
        let forOpposite = witnesses(standingUprightAt: opposite, in: readings)
        let (winner, won, lost) =
            forTurn.characters >= forOpposite.characters
            ? (turn, forTurn, forOpposite) : (opposite, forOpposite, forTurn)
        guard won.lines >= minimumLineOrderWitnesses,
            Double(won.characters) >= decisiveLineOrder * Double(lost.characters)
        else { return decision }
        let identity = max(scores[0] ?? 0, 0)
        decision.rotation = winner
        decision.gain = winner == 0 ? 1 : (identity > 0 ? (scores[winner] ?? 0) / identity : .infinity)
        decision.settledByLineOrder = true
        return decision
    }

    /// Lines that say the page stands upright at `turn`: read upright when it is turned so, or
    /// read upside down when it is turned the opposite way.
    private static func witnesses(
        standingUprightAt turn: Int, in readings: [Int: [RecognizedLine]]
    ) -> (lines: Int, characters: Int) {
        let lines =
            (readings[turn] ?? []).filter { $0.orientation == .upright }
            + (readings[(turn + 180) % 360] ?? []).filter { $0.orientation == .upsideDown }
        return (lines.count, lines.reduce(0) { $0 + $1.text.count })
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
