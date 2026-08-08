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
