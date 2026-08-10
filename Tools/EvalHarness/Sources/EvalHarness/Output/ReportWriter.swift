import Foundation

/// JSONL + Markdown report writer.
///
/// Privacy by default: metrics only. Document text and table cell contents are
/// included only when `includeContent` was set during the run (cells may already
/// be present on survey records).
public enum ReportWriter {
    public static func writeSurvey(
        _ summary: SurveySummary,
        outputDir: URL,
        configLabel: String
    ) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let jsonl = outputDir.appendingPathComponent("survey.jsonl")
        let md = outputDir.appendingPathComponent("survey.md")

        var lines: [String] = []
        for r in summary.records {
            var obj: [String: Any] = [
                "file": r.relativePath,
                "ingestionSeconds": round6(r.ingestionSeconds),
                "characterCount": r.characterCount,
                "positionedBlockCount": r.positionedBlockCount,
                "usedOCRFallback": r.usedOCRFallback,
                "tableCount": r.tableCount,
                "hasLineItemShaped": r.hasLineItemShaped,
            ]
            if let err = r.error { obj["error"] = err }
            obj["tables"] = r.tables.map { t -> [String: Any] in
                var d: [String: Any] = [
                    "pageIndex": t.pageIndex,
                    "rowCount": t.rowCount,
                    "columnCount": t.columnCount,
                    "fillDensity": round6(t.fillDensity),
                    "isLineItemShaped": t.isLineItemShaped,
                ]
                if let cells = t.cells {
                    d["cells"] = cells
                }
                return d
            }
            lines.append(jsonObjectLine(obj))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: jsonl, atomically: true, encoding: .utf8)

        var mdLines: [String] = [
            "# Survey report",
            "",
            "Config: \(configLabel)",
            "",
            "## Aggregate",
            "",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Files total | \(summary.filesTotal) |",
            "| Files OK | \(summary.filesOK) |",
            "| Files error | \(summary.filesError) |",
            "| OCR fallback | \(summary.ocrFallbackCount) |",
            "| Mean ingestion (s) | \(fmt(summary.meanIngestionSeconds)) |",
            "| Mean characters | \(fmt(summary.meanCharacterCount)) |",
            "| Mean tables/file | \(fmt(summary.meanTablesPerFile)) |",
            "| Line-item-shaped files | \(summary.filesWithLineItemShaped) / \(summary.filesOK) |",
            "| Line-item-shaped share | \(pct(summary.lineItemShapedShare)) |",
            "",
            "_Line-item-shaped = rows ≥ 3, columns 3–6, fill density ≥ 0.80._",
            "",
            "## Per file",
            "",
            "| File | chars | OCR fb | tables | line-item-shaped | ingest s | error |",
            "| --- | ---: | --- | ---: | --- | ---: | --- |",
        ]
        for r in summary.records {
            mdLines.append(
                "| \(r.relativePath) | \(r.characterCount) | \(r.usedOCRFallback) | \(r.tableCount) | \(r.hasLineItemShaped) | \(fmt(r.ingestionSeconds)) | \(r.error ?? "") |"
            )
        }
        mdLines.append("")
        try mdLines.joined(separator: "\n").write(to: md, atomically: true, encoding: .utf8)
    }

    public static func writeAccuracy(
        _ summary: AccuracySummary,
        outputDir: URL,
        configLabel: String
    ) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let jsonl = outputDir.appendingPathComponent("accuracy.jsonl")
        let md = outputDir.appendingPathComponent("accuracy.md")

        var lines: [String] = []
        for r in summary.records {
            var obj: [String: Any] = [
                "file": r.relativePath,
                "hasGroundTruth": r.hasGroundTruth,
                "paired": r.paired,
                "tableCount": r.tableCount,
                "hasLineItemShaped": r.hasLineItemShaped,
                "ingestionSeconds": round6(r.ingestionSeconds),
                "extractionSeconds": round6(r.extractionSeconds),
            ]
            if let u = r.unpairedReason { obj["unpairedReason"] = u }
            if let e = r.extractionError { obj["extractionError"] = e }
            // Metrics only — no predicted free-text values unless they are already
            // field score strings (truth/pred labels are short identifiers/amounts).
            obj["fields"] = r.fieldScores.map { f -> [String: Any] in
                [
                    "field": f.field,
                    "correct": f.correct,
                    "truthPresentInText": f.truthPresentInText,
                ]
            }
            lines.append(jsonObjectLine(obj))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: jsonl, atomically: true, encoding: .utf8)

        var mdLines: [String] = [
            "# Accuracy report",
            "",
            "Config: \(configLabel)",
            "",
            "## Aggregate",
            "",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Files total | \(summary.filesTotal) |",
            "| With Factur-X ground truth | \(summary.withGroundTruth) |",
            "| Unpaired (dropped) | \(summary.unpaired) |",
            "| Scored (paired) | \(summary.scored) |",
            "| Overall field accuracy | \(pct(summary.overallAccuracy)) (\(summary.overallCorrect)/\(summary.overallTotal)) |",
            "| Present-in-text accuracy | \(pct(summary.presentAccuracy)) (\(summary.presentCorrect)/\(summary.presentTotal)) |",
            "| Seller accuracy | \(summary.sellerAccuracy.map(pct) ?? "n/a") |",
            "| Line-item-shaped share | \(pct(summary.lineItemShapedShare)) (\(summary.filesWithLineItemShaped)/\(max(summary.filesTotal - summary.records.filter { $0.extractionError != nil }.count, 1))) |",
            "",
            "Present-in-text accuracy restricts to fields whose truth value appears in the extracted text (ZUGFeRD MINIMUM XML-only values are excluded).",
            "",
            "## Per field (overall)",
            "",
            "| Field | Accuracy | n |",
            "| --- | ---: | ---: |",
        ]
        for key in summary.perField.keys.sorted() {
            let pair = summary.perField[key]!
            let acc = pair.total == 0 ? 0 : Double(pair.correct) / Double(pair.total)
            mdLines.append("| \(key) | \(pct(acc)) | \(pair.total) |")
        }
        mdLines.append(contentsOf: [
            "",
            "## Per field (present in text)",
            "",
            "| Field | Accuracy | n |",
            "| --- | ---: | ---: |",
        ])
        for key in summary.perFieldPresent.keys.sorted() {
            let pair = summary.perFieldPresent[key]!
            let acc = pair.total == 0 ? 0 : Double(pair.correct) / Double(pair.total)
            mdLines.append("| \(key) | \(pct(acc)) | \(pair.total) |")
        }
        mdLines.append(contentsOf: [
            "",
            "## Unpaired files",
            "",
        ])
        let unpaired = summary.records.filter { $0.hasGroundTruth && !$0.paired }
        if unpaired.isEmpty {
            mdLines.append("_None._")
        } else {
            for r in unpaired {
                mdLines.append("- \(r.relativePath): \(r.unpairedReason ?? "")")
            }
        }
        mdLines.append("")
        try mdLines.joined(separator: "\n").write(to: md, atomically: true, encoding: .utf8)
    }

    public static func writeCompare(
        _ summary: ABCompareSummary,
        outputDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let jsonl = outputDir.appendingPathComponent("compare.jsonl")
        let md = outputDir.appendingPathComponent("compare.md")

        var lines: [String] = []
        for f in summary.changedFiles {
            let obj: [String: Any] = [
                "file": f.relativePath,
                "fieldDeltas": f.fieldDeltas.map { d -> [String: Any] in
                    [
                        "field": d.field,
                        "aCorrect": d.aCorrect as Any,
                        "bCorrect": d.bCorrect as Any,
                        "delta": d.delta,
                    ]
                },
            ]
            lines.append(jsonObjectLine(obj))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: jsonl, atomically: true, encoding: .utf8)

        var mdLines: [String] = [
            "# A/B comparison",
            "",
            "Arm A: \(summary.configALabel)",
            "",
            "Arm B: \(summary.configBLabel)",
            "",
            "| | \(summary.configA) | \(summary.configB) | Δ (pp) |",
            "| --- | ---: | ---: | ---: |",
            "| Overall accuracy | \(pct(summary.summaryA.overallAccuracy)) | \(pct(summary.summaryB.overallAccuracy)) | \(fmtSigned(summary.overallDeltaPP)) |",
            "| Present-in-text accuracy | \(pct(summary.summaryA.presentAccuracy)) | \(pct(summary.summaryB.presentAccuracy)) | \(fmtSigned(summary.presentDeltaPP)) |",
            "",
            "## Per-field Δ (pp, B − A)",
            "",
            "| Field | Δ pp |",
            "| --- | ---: |",
        ]
        for key in summary.perFieldDeltaPP.keys.sorted() {
            mdLines.append("| \(key) | \(fmtSigned(summary.perFieldDeltaPP[key]!)) |")
        }
        mdLines.append(contentsOf: [
            "",
            "## Files that changed (\(summary.changedFiles.count))",
            "",
        ])
        if summary.changedFiles.isEmpty {
            mdLines.append("_None._")
        } else {
            for f in summary.changedFiles {
                mdLines.append("### \(f.relativePath)")
                for d in f.fieldDeltas {
                    mdLines.append(
                        "- \(d.field): A=\(d.aCorrect.map(String.init(describing:)) ?? "n/a") B=\(d.bCorrect.map(String.init(describing:)) ?? "n/a") (Δ \(d.delta))"
                    )
                }
                mdLines.append("")
            }
        }
        try mdLines.joined(separator: "\n").write(to: md, atomically: true, encoding: .utf8)
    }

    public static func writeChunkMerge(
        _ summary: ChunkMergeSummary,
        outputDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let jsonl = outputDir.appendingPathComponent("chunk-merge.jsonl")
        let md = outputDir.appendingPathComponent("chunk-merge.md")

        var lines: [String] = []
        for r in summary.records {
            var obj: [String: Any] = [
                "file": r.relativePath,
                "characterCount": r.characterCount,
                "pageCountEstimate": r.pageCountEstimate,
                "tableCount": r.tableCount,
                "tablePageIndices": r.tablePageIndices,
                "hasGroundTruth": r.hasGroundTruth,
                "paired": r.paired,
                "diagnosticsCount": r.diagnostics.count,
            ]
            if let u = r.unpairedReason { obj["unpairedReason"] = u }
            if let a = r.armA {
                obj["armA"] = armMetrics(a)
            }
            if let b = r.armB {
                obj["armB"] = armMetrics(b)
            }
            lines.append(jsonObjectLine(obj))
        }
        try lines.joined(separator: "\n").appending("\n").write(
            to: jsonl, atomically: true, encoding: .utf8
        )

        func acc(_ pair: (correct: Int, total: Int)) -> String {
            guard pair.total > 0 else { return "n/a" }
            return pct(Double(pair.correct) / Double(pair.total))
                + " (\(pair.correct)/\(pair.total))"
        }
        func deltaPP(_ a: (Int, Int), _ b: (Int, Int)) -> String {
            guard a.1 > 0, b.1 > 0 else { return "n/a" }
            let da = Double(a.0) / Double(a.1)
            let db = Double(b.0) / Double(b.1)
            return fmtSigned((db - da) * 100.0)
        }

        var mdLines: [String] = [
            "# Chunk-merge experiment (A vs B)",
            "",
            summary.backendLabel,
            "",
            "| Arm | softContextCharacterBudget | role |",
            "| --- | ---: | --- |",
            "| **A** | \(summary.budgetA) | baseline (single chunk when doc fits) |",
            "| **B** | \(summary.budgetB) | forced chunking |",
            "",
            "## Aggregate",
            "",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Files total | \(summary.filesTotal) |",
            "| With Factur-X GT | \(summary.withGroundTruth) |",
            "| Unpaired | \(summary.unpaired) |",
            "| Scored (paired, extracted) | \(summary.scored) |",
            "| Arm B files with chunksUsed > 1 | \(summary.chunkedB) |",
            "| Failures A / B | \(summary.failuresA) / \(summary.failuresB) |",
            "| Mean attempts A / B | \(fmt(summary.meanAttemptsA)) / \(fmt(summary.meanAttemptsB)) |",
            "| Mean chunksUsed A / B | \(fmt(summary.meanChunksA)) / \(fmt(summary.meanChunksB)) |",
            "| Overall accuracy A | \(acc(summary.overallA)) |",
            "| Overall accuracy B | \(acc(summary.overallB)) |",
            "| Overall Δ (B−A, pp) | \(deltaPP(summary.overallA, summary.overallB)) |",
            "| Header fields A | \(acc(summary.headerFieldsA)) |",
            "| Header fields B | \(acc(summary.headerFieldsB)) |",
            "| Header Δ pp | \(deltaPP(summary.headerFieldsA, summary.headerFieldsB)) |",
            "| Line description A | \(acc(summary.lineDescA)) |",
            "| Line description B | \(acc(summary.lineDescB)) |",
            "| Line description Δ pp | \(deltaPP(summary.lineDescA, summary.lineDescB)) |",
            "| Line amount A | \(acc(summary.lineAmtA)) |",
            "| Line amount B | \(acc(summary.lineAmtB)) |",
            "| Line amount Δ pp | \(deltaPP(summary.lineAmtA, summary.lineAmtB)) |",
            "| Line count exact A / B | \(summary.lineCountExactA) / \(summary.lineCountExactB) of \(summary.lineCountScored) |",
            "| Lost line items (B, sum) | \(summary.lostItemsTotalB) |",
            "| Extra line items (B, sum) | \(summary.extraItemsTotalB) |",
            "| Duplicate predicted descs (B, sum) | \(summary.dupItemsTotalB) |",
            "| Provenance rate A / B | \(pct(summary.provenanceRateA)) / \(pct(summary.provenanceRateB)) |",
            "| Grounded (verbatim/norm) without provenance A / B | \(summary.groundedWithoutProvA) / \(summary.groundedWithoutProvB) |",
            "| Mean wall-clock s A / B | \(fmt(summary.meanSecondsA)) / \(fmt(summary.meanSecondsB)) |",
            "| Sum wall-clock s A / B | \(fmt(summary.sumSecondsA)) / \(fmt(summary.sumSecondsB)) |",
            "",
            "## Invariant / repair (EvalInvoice: lineItems + tax ≈ grandTotal)",
            "",
            "| Metric | A | B |",
            "| --- | ---: | ---: |",
            "| Files with ≥1 invariant violation | \(summary.invariantTriggeredA) | \(summary.invariantTriggeredB) |",
            "| Of those: extraction recovered (returned value) | \(summary.invariantRecoveredA) | \(summary.invariantRecoveredB) |",
            "| Of those: still `validationFailed` (invariant) | \(summary.invariantStillFailedA) | \(summary.invariantStillFailedB) |",
            "| Recovered + grandTotal correct vs GT | \(summary.invariantRecoveredGrandTotalCorrectA) | \(summary.invariantRecoveredGrandTotalCorrectB) |",
            "",
            "## Per-field accuracy (paired successful scores)",
            "",
            "| Field | A | B | Δ pp |",
            "| --- | ---: | ---: | ---: |",
        ]

        let allFields = Set(summary.perFieldA.keys).union(summary.perFieldB.keys).sorted()
        for field in allFields {
            let a = summary.perFieldA[field] ?? (0, 0)
            let b = summary.perFieldB[field] ?? (0, 0)
            mdLines.append(
                "| \(field) | \(acc(a)) | \(acc(b)) | \(deltaPP(a, b)) |"
            )
        }

        mdLines.append(contentsOf: [
            "",
            "## Files where line items diverged (B vs truth or A)",
            "",
        ])

        var lossExamples = 0
        for r in summary.records where r.paired {
            guard let a = r.armA, let b = r.armB else { continue }
            let lineChanged =
                a.predictedLineItemCount != b.predictedLineItemCount
                || !b.lostDescriptions.isEmpty
                || !b.extraDescriptions.isEmpty
                || b.duplicatePredictedDescriptions > 0
                || a.extractionError != nil
                || b.extractionError != nil
            guard lineChanged else { continue }
            lossExamples += 1
            mdLines.append("### \(r.relativePath)")
            mdLines.append("")
            mdLines.append(
                "- chars=\(r.characterCount) pages≈\(r.pageCountEstimate) tables=\(r.tableCount) chunks A/B=\(a.chunksUsed)/\(b.chunksUsed) attempts A/B=\(a.attempts)/\(b.attempts) s A/B=\(String(format: "%.1f", a.extractionSeconds))/\(String(format: "%.1f", b.extractionSeconds))"
            )
            if a.invariantTriggered || b.invariantTriggered {
                mdLines.append(
                    "- invariants: A viol=\(a.invariantViolations)/checks=\(a.invariantChecks) skip=\(a.invariantSkips)\(a.invariantValidationFailed ? " validationFailed" : a.extractionError == nil && a.invariantTriggered ? " recovered" : ""); B viol=\(b.invariantViolations)/checks=\(b.invariantChecks) skip=\(b.invariantSkips)\(b.invariantValidationFailed ? " validationFailed" : b.extractionError == nil && b.invariantTriggered ? " recovered" : "")"
                )
            }
            if let e = a.extractionError {
                mdLines.append("- **A error:** \(shortError(e))")
            }
            if let e = b.extractionError {
                mdLines.append("- **B error:** \(shortError(e))")
            }
            mdLines.append(
                "- truth line count=\(b.truthLineItemCount); predicted A=\(a.predictedLineItemCount) B=\(b.predictedLineItemCount) (ΔB=\(b.lineItemCountDelta))"
            )
            mdLines.append(
                "- B dups=\(b.duplicatePredictedDescriptions) lost=\(b.lostDescriptions.count) extra=\(b.extraDescriptions.count)"
            )
            // Concrete values (short): needed to judge merge loss; keep to line-item fields.
            if !b.truthDescriptions.isEmpty {
                mdLines.append(
                    "- truth descs: \(b.truthDescriptions.map(quote).joined(separator: " | "))"
                )
            }
            if !a.predictedDescriptions.isEmpty {
                mdLines.append(
                    "- A pred descs: \(a.predictedDescriptions.map(quote).joined(separator: " | "))"
                )
            }
            if !b.predictedDescriptions.isEmpty {
                mdLines.append(
                    "- B pred descs: \(b.predictedDescriptions.map(quote).joined(separator: " | "))"
                )
            }
            if !b.lostDescriptions.isEmpty {
                mdLines.append(
                    "- **lost on B:** \(b.lostDescriptions.map(quote).joined(separator: " | "))"
                )
            }
            if !b.extraDescriptions.isEmpty {
                mdLines.append(
                    "- **extra on B:** \(b.extraDescriptions.map(quote).joined(separator: " | "))"
                )
            }
            // Header field flips
            let fa = Dictionary(uniqueKeysWithValues: a.fieldScores.map { ($0.field, $0) })
            let fb = Dictionary(uniqueKeysWithValues: b.fieldScores.map { ($0.field, $0) })
            for field in Set(fa.keys).union(fb.keys).sorted() {
                let ca = fa[field]
                let cb = fb[field]
                guard let ca, let cb, ca.correct != cb.correct else { continue }
                mdLines.append(
                    "- field \(field): A=\(ca.correct ? "ok" : "miss") B=\(cb.correct ? "ok" : "miss") truth=\(quote(ca.truthValue ?? "")) Apred=\(quote(ca.predictedValue ?? "nil")) Bpred=\(quote(cb.predictedValue ?? "nil"))"
                )
            }
            mdLines.append(
                "- provenance fields A \(a.signalsWithProvenance)/\(a.signalsFieldCount); B \(b.signalsWithProvenance)/\(b.signalsFieldCount)"
            )
            if !b.sampleProvenancePaths.isEmpty {
                mdLines.append(
                    "- B sample provenance paths: \(b.sampleProvenancePaths.joined(separator: ", "))"
                )
            }
            mdLines.append("")
        }
        if lossExamples == 0 {
            mdLines.append("_No line-item divergences recorded._")
            mdLines.append("")
        }

        mdLines.append(contentsOf: [
            "## Layout diagnostics (pre-model, budget B)",
            "",
        ])
        var diagCount = 0
        for r in summary.records {
            let interesting = r.diagnostics.filter {
                $0.contains("hard-split") || $0.contains("table") || $0.contains("WARNING")
                    || $0.contains("cell texts absent")
            }
            guard !interesting.isEmpty else { continue }
            diagCount += 1
            mdLines.append("### \(r.relativePath)")
            for d in interesting.prefix(12) {
                mdLines.append("- \(d)")
            }
            if interesting.count > 12 {
                mdLines.append("- … +\(interesting.count - 12) more")
            }
            mdLines.append("")
        }
        if diagCount == 0 {
            mdLines.append("_No hard-split / table-assignment notes._")
            mdLines.append("")
        }

        mdLines.append(contentsOf: [
            "## Code-path notes (invariants / merge repair)",
            "",
            "`EvalInvoice.validateInvariants()` checks line-item `lineTotal` sum + tax ≈ `grandTotal`",
            "within `Extract.defaultMoneyTolerance` (0.01). Skips when line items are missing, grandTotal",
            "is nil, or any line lacks `lineTotal`. Missing tax is treated as zero.",
            "Library merge path (Extract.swift): after partials, `ChunkJSONMerger` merges JSON trees",
            "deterministically (grounding-arbitrated scalars; ungrounded array text dropped; no LLM merge).",
            "On decode/invariant failure the single-chunk-style repair prompt is used against the full",
            "document. Equal-rank merge conflicts surface on `result.signals.mergeConflicts`.",
            "Invariants are validated once after each decode attempt (merge decode + each model repair).",
            "",
            "Grounding / provenance: `FieldGrounding.compute` is called with the **full** document",
            "`sourceText` and full-document `blocks`/`tables` even when `chunksUsed > 1`.",
            "",
            "Honest interpretation: invariants are **caller-supplied**. Recovery here measures the",
            "safety net on this schema, not a free accuracy gain in the library merge path alone.",
            "",
        ])

        try mdLines.joined(separator: "\n").write(to: md, atomically: true, encoding: .utf8)
    }

    private static func armMetrics(_ a: ChunkMergeArmRecord) -> [String: Any] {
        var m: [String: Any] = [
            "softBudget": a.softBudget,
            "chunksUsed": a.chunksUsed,
            "attempts": a.attempts,
            "extractionSeconds": round6(a.extractionSeconds),
            "predictedLineItemCount": a.predictedLineItemCount,
            "truthLineItemCount": a.truthLineItemCount,
            "lineItemCountDelta": a.lineItemCountDelta,
            "duplicatePredictedDescriptions": a.duplicatePredictedDescriptions,
            "lostCount": a.lostDescriptions.count,
            "extraCount": a.extraDescriptions.count,
            "signalsFieldCount": a.signalsFieldCount,
            "signalsWithProvenance": a.signalsWithProvenance,
            "groundedWithoutProvenance": a.groundedWithoutProvenance,
            "groundingCounts": a.groundingCounts,
            "fieldCorrect": a.fieldScores.filter(\.correct).count,
            "fieldTotal": a.fieldScores.count,
            "invariantChecks": a.invariantChecks,
            "invariantViolations": a.invariantViolations,
            "invariantSkips": a.invariantSkips,
            "invariantTriggered": a.invariantTriggered,
            "invariantValidationFailed": a.invariantValidationFailed,
        ]
        if let e = a.extractionError { m["extractionError"] = shortError(e) }
        return m
    }

    private static func shortError(_ e: String) -> String {
        if e.count <= 240 { return e }
        return String(e.prefix(240)) + "…"
    }

    private static func quote(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if t.count <= 80 { return "\"\(t)\"" }
        return "\"\(t.prefix(77))…\""
    }

    public static func writeAnchors(
        _ summary: AnchorRunSummary,
        outputDir: URL
    ) throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let jsonl = outputDir.appendingPathComponent("anchors.jsonl")
        let md = outputDir.appendingPathComponent("anchors.md")

        var lines: [String] = []
        for r in summary.results {
            let obj: [String: Any] = [
                "id": r.id,
                "path": r.path,
                "status": r.status.rawValue,
                "messages": r.messages,
            ]
            lines.append(jsonObjectLine(obj))
        }
        try lines.joined(separator: "\n").appending("\n").write(to: jsonl, atomically: true, encoding: .utf8)

        var mdLines: [String] = [
            "# Anchor report",
            "",
            "| Status | Count |",
            "| --- | ---: |",
            "| passed | \(summary.passed) |",
            "| failed | \(summary.failed) |",
            "| skipped | \(summary.skipped) |",
            "",
        ]
        for r in summary.results {
            mdLines.append("## \(r.id) — \(r.status.rawValue)")
            mdLines.append("")
            mdLines.append("Path: `\(r.path)`")
            mdLines.append("")
            for m in r.messages {
                mdLines.append("- \(m)")
            }
            mdLines.append("")
        }
        try mdLines.joined(separator: "\n").write(to: md, atomically: true, encoding: .utf8)
    }

    // MARK: - helpers

    private static func round6(_ x: Double) -> Double {
        (x * 1_000_000).rounded() / 1_000_000
    }

    private static func fmt(_ x: Double) -> String {
        String(format: "%.4f", x)
    }

    private static func fmtSigned(_ x: Double) -> String {
        String(format: "%+.2f", x)
    }

    private static func pct(_ x: Double) -> String {
        String(format: "%.1f%%", x * 100)
    }

    private static func jsonObjectLine(_ obj: [String: Any]) -> String {
        // Deterministic key order via JSONSerialization + sorted rebuild is awkward;
        // use JSONSerialization (stable enough for equal inputs on same runtime).
        guard let data = try? JSONSerialization.data(
            withJSONObject: sortedJSON(obj),
            options: [.sortedKeys]
        ),
            let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }

    private static func sortedJSON(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for k in dict.keys.sorted() {
                out[k] = sortedJSON(dict[k]!)
            }
            return out
        }
        if let arr = value as? [Any] {
            return arr.map { sortedJSON($0) }
        }
        return value
    }
}
