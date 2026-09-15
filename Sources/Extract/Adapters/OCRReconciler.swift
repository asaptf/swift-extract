import CoreGraphics
import Foundation

/// Pair OCR lines from several passes of the same page by geometry, and keep every
/// distinct reading.
///
/// Agreeing lines collapse to one block at full agreement. Disagreeing lines both
/// survive: picking a winner would recreate the problem this exists to solve — a
/// wrong cell that looks exactly like a right one. A pass that returned nothing
/// for the page is dropped before the vote, so a failed raster cannot lower
/// agreement on lines the other pass actually read.
enum OCRReconciler {
    /// Pairing is tolerant of the small box drift two DPIs produce (a couple of
    /// percent of the page) and intolerant of a different line: the next printed
    /// row is a whole line-height away.
    static let minimumIoU: CGFloat = 0.25

    static func reconcile(_ passes: [[ExtractedDocument.Block]]) -> [ExtractedDocument.Block] {
        let observing = passes.filter { blocks in
            blocks.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        let observingCount = observing.count
        guard observingCount > 0 else { return [] }
        if observingCount == 1 {
            return observing[0].map { block in
                var copy = block
                copy.agreement = .unanimous(passes: 1)
                return copy
            }
        }

        var unmatched: [PassLine] = []
        for (passIndex, blocks) in observing.enumerated() {
            for block in blocks {
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let box = block.boundingBox else {
                    unmatched.append(
                        PassLine(
                            passIndex: passIndex, text: text, block: block, box: block.boundingBox)
                    )
                    continue
                }
                unmatched.append(PassLine(passIndex: passIndex, text: text, block: block, box: box))
            }
        }

        var clusters: [[PassLine]] = []
        while let seedIndex = unmatched.firstIndex(where: { _ in true }) {
            let seed = unmatched.remove(at: seedIndex)
            var cluster = [seed]
            var clusterBox = seed.box
            var found = true
            while found {
                found = false
                let takenPasses = Set(cluster.map(\.passIndex))
                var bestIndex: Int?
                var bestScore: CGFloat = -1
                for (index, candidate) in unmatched.enumerated() {
                    guard !takenPasses.contains(candidate.passIndex) else { continue }
                    guard let score = pairScore(clusterBox, candidate.box) else { continue }
                    if score > bestScore {
                        bestScore = score
                        bestIndex = index
                    }
                }
                if let bestIndex {
                    let match = unmatched.remove(at: bestIndex)
                    cluster.append(match)
                    clusterBox = union(clusterBox, match.box)
                    found = true
                }
            }
            clusters.append(cluster)
        }

        var result: [ExtractedDocument.Block] = []
        for cluster in clusters {
            let byText = Dictionary(grouping: cluster, by: \.text)
            for (text, lines) in byText {
                let representative = lines[0].block
                var block = representative
                block.text = text.isEmpty ? representative.text : text
                block.agreement = OCRAgreement(
                    matchingPasses: lines.count, observingPasses: observingCount)
                result.append(block)
            }
        }
        return result
    }

    /// IoU when both boxes exist; otherwise only identical-nil pairs, so a line
    /// without geometry does not absorb a positioned one.
    static func pairScore(_ a: CGRect?, _ b: CGRect?) -> CGFloat? {
        switch (a, b) {
        case (nil, nil):
            return 1
        case (let aBox?, let bBox?):
            return geometryScore(aBox, bBox)
        default:
            return nil
        }
    }

    /// Whether two normalised line boxes are the same printed line at two DPIs.
    static func geometryPairs(_ a: CGRect, _ b: CGRect) -> Bool {
        geometryScore(a, b) != nil
    }

    private static func geometryScore(_ a: CGRect, _ b: CGRect) -> CGFloat? {
        let overlap = a.intersection(b)
        let overlapArea: CGFloat
        if overlap.isNull || overlap.width <= 0 || overlap.height <= 0 {
            overlapArea = 0
        } else {
            overlapArea = overlap.width * overlap.height
        }
        let unionArea = a.width * a.height + b.width * b.height - overlapArea
        let iou = unionArea > 0 ? overlapArea / unionArea : 0

        let sameLine = abs(a.midY - b.midY) <= max(max(a.height, b.height) * 0.6, 0.008)
        let overlapW = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let minW = min(a.width, b.width)
        let horizontal = minW > 0 && overlapW / minW >= 0.25

        if iou >= minimumIoU { return iou }
        if sameLine && horizontal { return max(iou, 0.01) }
        return nil
    }

    private static func union(_ a: CGRect?, _ b: CGRect?) -> CGRect? {
        switch (a, b) {
        case (let aBox?, let bBox?):
            return aBox.union(bBox)
        case (let aBox?, nil):
            return aBox
        case (nil, let bBox?):
            return bBox
        case (nil, nil):
            return nil
        }
    }

    private struct PassLine {
        var passIndex: Int
        var text: String
        var block: ExtractedDocument.Block
        var box: CGRect?
    }
}
