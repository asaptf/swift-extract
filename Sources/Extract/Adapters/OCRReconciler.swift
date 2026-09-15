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
            // A cluster the caller's own pass never saw is not a line of this page; it is
            // handled below as evidence against the nearest line that pass did read.
            guard cluster.contains(where: { $0.passIndex == 0 }) else { continue }
            // The first pass is the one the caller configured; its reading is the page. Other
            // readings are evidence hung off that line, never text of their own — putting them
            // in the text is what doubled the page and cost thirteen points of accuracy.
            let primary = cluster.min { $0.passIndex < $1.passIndex }
            guard let anchor = primary ?? cluster.first else { continue }
            let text = anchor.text.isEmpty ? anchor.block.text : anchor.text
            var block = anchor.block
            block.text = text
            let matching = cluster.filter { $0.text == text }.count
            block.agreement = OCRAgreement(
                matchingPasses: matching, observingPasses: observingCount)
            var seen: Set<String> = [text]
            block.alternatives = cluster.compactMap { line in
                guard !line.text.isEmpty, !seen.contains(line.text) else { return nil }
                seen.insert(line.text)
                return line.text
            }
            result.append(block)
        }
        // A line only a later pass saw is not added to the page either: it is recorded against
        // the nearest line the caller's own pass did read, so the disagreement survives without
        // the model ever being shown text its configured pass did not produce.
        return attachOrphans(result, clusters: clusters, observingCount: observingCount)
    }

    /// Clusters that contain no line from the caller's own pass.
    ///
    /// Two kinds, and they are not the same thing. A cluster that sits **on top of** a line the
    /// caller did read is another reading of it: it stays an alternative, because putting it in
    /// the page doubles the text and costs more than it buys. A cluster with nothing under it is
    /// a **gap** — a line the caller's pass missed entirely — and it is added, because filling
    /// gaps is the whole reason to read a page twice. Measured on macOS 27, whose recogniser
    /// drops barcodes this scan used to read: one pass finds 75 of 86, another finds 73, and
    /// their union is 83 because they miss different ones.
    private static func attachOrphans(
        _ kept: [ExtractedDocument.Block],
        clusters: [[PassLine]],
        observingCount: Int
    ) -> [ExtractedDocument.Block] {
        var blocks = kept
        for cluster in clusters where !cluster.contains(where: { $0.passIndex == 0 }) {
            guard let orphan = cluster.first, !orphan.text.isEmpty else { continue }
            guard !blocks.contains(where: { $0.text == orphan.text }) else { continue }
            if let overlapping = overlappingIndex(of: orphan, in: blocks) {
                if blocks[overlapping].alternatives.contains(orphan.text) { continue }
                blocks[overlapping].alternatives.append(orphan.text)
                blocks[overlapping].agreement = OCRAgreement(
                    matchingPasses: min(blocks[overlapping].agreement.matchingPasses, 1),
                    observingPasses: observingCount)
                continue
            }
            var filled = orphan.block
            filled.text = orphan.text
            filled.agreement = OCRAgreement(matchingPasses: 1, observingPasses: observingCount)
            blocks.append(filled)
        }
        return blocks
    }

    /// The kept line this reading sits on, when there is one.
    private static func overlappingIndex(of line: PassLine, in blocks: [ExtractedDocument.Block]) -> Int? {
        guard let box = line.box else { return nil }
        for (index, block) in blocks.enumerated() {
            guard block.pageIndex == line.block.pageIndex, let other = block.boundingBox else {
                continue
            }
            if pairScore(other, box) != nil { return index }
        }
        return nil
    }

    private static func nearestIndex(to line: PassLine, in blocks: [ExtractedDocument.Block]) -> Int? {
        guard let box = line.box else { return blocks.isEmpty ? nil : 0 }
        var best: (index: Int, distance: CGFloat)?
        for (index, block) in blocks.enumerated() {
            guard block.pageIndex == line.block.pageIndex, let other = block.boundingBox else {
                continue
            }
            let distance = abs(other.midY - box.midY)
            if best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best?.index
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
