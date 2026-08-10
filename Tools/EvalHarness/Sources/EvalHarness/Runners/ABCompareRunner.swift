import Foundation

public struct ABFileDelta: Sendable {
    public var relativePath: String
    public var fieldDeltas: [FieldDelta]
    public var changed: Bool

    public struct FieldDelta: Sendable {
        public var field: String
        public var aCorrect: Bool?
        public var bCorrect: Bool?
        public var delta: Int  // +1 B better, -1 B worse, 0 same / incomparable
    }
}

public struct ABCompareSummary: Sendable {
    public var configA: String
    public var configB: String
    /// Full report labels (backend, tableDetection, invariant mode).
    public var configALabel: String
    public var configBLabel: String
    public var summaryA: AccuracySummary
    public var summaryB: AccuracySummary
    public var perFieldDeltaPP: [String: Double]
    public var overallDeltaPP: Double
    public var presentDeltaPP: Double
    public var changedFiles: [ABFileDelta]
}

public enum ABCompareRunner {
    public static func run(
        files: [URL],
        rootForRelative: URL,
        configA: RunConfig,
        configB: RunConfig
    ) async throws -> ABCompareSummary {
        let a = try await AccuracyRunner.run(
            files: files,
            rootForRelative: rootForRelative,
            config: configA
        )
        let b = try await AccuracyRunner.run(
            files: files,
            rootForRelative: rootForRelative,
            config: configB
        )

        let fields = Set(a.perField.keys).union(b.perField.keys).sorted()
        var deltas: [String: Double] = [:]
        for f in fields {
            let aa = accuracy(a.perField[f])
            let bb = accuracy(b.perField[f])
            deltas[f] = (bb - aa) * 100.0
        }

        var changed: [ABFileDelta] = []
        let byA = Dictionary(uniqueKeysWithValues: a.records.map { ($0.relativePath, $0) })
        let byB = Dictionary(uniqueKeysWithValues: b.records.map { ($0.relativePath, $0) })
        for path in Set(byA.keys).union(byB.keys).sorted() {
            let ra = byA[path]
            let rb = byB[path]
            let fa = Dictionary(uniqueKeysWithValues: (ra?.fieldScores ?? []).map { ($0.field, $0) })
            let fb = Dictionary(uniqueKeysWithValues: (rb?.fieldScores ?? []).map { ($0.field, $0) })
            var fieldDeltas: [ABFileDelta.FieldDelta] = []
            for field in Set(fa.keys).union(fb.keys).sorted() {
                let ca = fa[field]?.correct
                let cb = fb[field]?.correct
                let d: Int
                switch (ca, cb) {
                case (true, false): d = -1
                case (false, true): d = 1
                default: d = 0
                }
                if d != 0 {
                    fieldDeltas.append(
                        ABFileDelta.FieldDelta(field: field, aCorrect: ca, bCorrect: cb, delta: d)
                    )
                }
            }
            if !fieldDeltas.isEmpty
                || (ra?.extractionError != nil) != (rb?.extractionError != nil)
            {
                changed.append(
                    ABFileDelta(relativePath: path, fieldDeltas: fieldDeltas, changed: true)
                )
            }
        }

        return ABCompareSummary(
            configA: configA.name,
            configB: configB.name,
            configALabel: configA.reportLabel,
            configBLabel: configB.reportLabel,
            summaryA: a,
            summaryB: b,
            perFieldDeltaPP: deltas,
            overallDeltaPP: (b.overallAccuracy - a.overallAccuracy) * 100.0,
            presentDeltaPP: (b.presentAccuracy - a.presentAccuracy) * 100.0,
            changedFiles: changed
        )
    }

    private static func accuracy(_ pair: (correct: Int, total: Int)?) -> Double {
        guard let pair, pair.total > 0 else { return 0 }
        return Double(pair.correct) / Double(pair.total)
    }
}
