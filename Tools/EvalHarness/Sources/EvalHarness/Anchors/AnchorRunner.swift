import Extract
import Foundation

public struct AnchorRunSummary: Sendable {
    public var results: [AnchorResult]

    public var passed: Int { results.filter { $0.status == .passed }.count }
    public var failed: Int { results.filter { $0.status == .failed }.count }
    public var skipped: Int { results.filter { $0.status == .skipped }.count }

    public var allRequiredPassed: Bool {
        results.allSatisfy { $0.status != .failed }
    }
}

public enum AnchorRunner {
    /// Evaluate anchors. Paths without `requiresCorpus` resolve against `repoRoot`;
    /// corpus anchors resolve against `corpusRoot` (substring / filename match allowed).
    public static func run(
        anchors: [Anchor],
        repoRoot: URL,
        corpusRoot: URL?,
        tableDetection: TableDetectionMode = .automatic
    ) async -> AnchorRunSummary {
        var results: [AnchorResult] = []
        for anchor in anchors {
            let result = await evaluate(
                anchor: anchor,
                repoRoot: repoRoot,
                corpusRoot: corpusRoot,
                tableDetection: tableDetection
            )
            results.append(result)
        }
        return AnchorRunSummary(results: results)
    }

    private static func evaluate(
        anchor: Anchor,
        repoRoot: URL,
        corpusRoot: URL?,
        tableDetection: TableDetectionMode
    ) async -> AnchorResult {
        guard let fileURL = resolveFile(
            path: anchor.path,
            requiresCorpus: anchor.requiresCorpus,
            repoRoot: repoRoot,
            corpusRoot: corpusRoot
        ) else {
            if anchor.requiresCorpus {
                return AnchorResult(
                    id: anchor.id,
                    path: anchor.path,
                    status: .skipped,
                    messages: [
                        "Skipped: corpus file matching '\(anchor.path)' not found (corpus \(corpusRoot?.path ?? "absent"))."
                    ]
                )
            }
            return AnchorResult(
                id: anchor.id,
                path: anchor.path,
                status: .failed,
                messages: ["File not found: \(anchor.path) (repo root \(repoRoot.path))"]
            )
        }

        do {
            let inspection = try await Extract.inspect(
                fileURL,
                tableDetection: tableDetection
            )
            var messages: [String] = []
            var failed = false
            for check in anchor.checks {
                let (ok, msg) = evaluateCheck(check, inspection: inspection)
                if ok {
                    messages.append("PASS \(check.type.rawValue): \(msg)")
                } else {
                    failed = true
                    messages.append("FAIL \(check.type.rawValue): \(msg)")
                }
            }
            return AnchorResult(
                id: anchor.id,
                path: fileURL.path,
                status: failed ? .failed : .passed,
                messages: messages
            )
        } catch {
            return AnchorResult(
                id: anchor.id,
                path: fileURL.path,
                status: .failed,
                messages: ["Inspection error: \(error)"]
            )
        }
    }

    private static func evaluateCheck(
        _ check: AnchorCheck,
        inspection: DocumentInspection
    ) -> (Bool, String) {
        switch check.type {
        case .tableContainsCells:
            let needed = check.values ?? []
            guard !needed.isEmpty else { return (false, "no values configured") }
            let tables = inspection.tables
            let hit = tables.first { table in
                let joined = table.cells.map(\.text).joined(separator: " ")
                return needed.allSatisfy {
                    FieldNormalization.textContains(joined, needle: $0)
                }
            }
            if hit != nil {
                return (true, "found cells \(needed) in a table")
            }
            let preview = tables.map {
                "\($0.rowCount)x\($0.columnCount) d=\(String(format: "%.2f", TableMetrics.fillDensity($0)))"
            }.joined(separator: ", ")
            return (false, "no table contained \(needed); tables=[\(preview)]")

        case .exactTableCount:
            let n = check.count ?? -1
            let ok = inspection.tables.count == n
            return (ok, "tables=\(inspection.tables.count) expected=\(n)")

        case .minTableCount:
            let n = check.count ?? 1
            let ok = inspection.tables.count >= n
            return (ok, "tables=\(inspection.tables.count) min=\(n)")

        case .hasLineItemShapedTable:
            let ok = TableMetrics.hasLineItemShapedTable(inspection.tables)
            return (
                ok,
                ok
                    ? "line-item-shaped table present"
                    : "no line-item-shaped table (rows≥3, cols 3–6, density≥0.80)"
            )

        case .sellerEquals:
            // Seller equality requires model extraction; for anchors we check text presence
            // of the expected seller string (deterministic, no backend).
            guard let expected = check.value, !expected.isEmpty else {
                return (false, "no value configured")
            }
            let ok = FieldNormalization.textContains(inspection.fullText, needle: expected)
            return (ok, ok ? "text contains seller '\(expected)'" : "text missing seller '\(expected)'")

        case .textContains:
            let needed = check.values ?? []
            let missing = needed.filter { !FieldNormalization.textContains(inspection.fullText, needle: $0) }
            if missing.isEmpty {
                return (true, "text contains \(needed)")
            }
            return (false, "text missing \(missing)")
        }
    }

    /// Resolve an anchor path.
    ///
    /// - Fixture paths: `repoRoot/path` or absolute.
    /// - Corpus paths: exact path under corpus, or first file whose path/name contains
    ///   the token (case-insensitive), so anchors can say `coolblue` without a full name.
    public static func resolveFile(
        path: String,
        requiresCorpus: Bool,
        repoRoot: URL,
        corpusRoot: URL?
    ) -> URL? {
        let fm = FileManager.default
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            return fm.fileExists(atPath: url.path) ? url : nil
        }

        if !requiresCorpus {
            let candidate = repoRoot.appendingPathComponent(path)
            if fm.fileExists(atPath: candidate.path) { return candidate }
            // Also try relative to cwd.
            let cwd = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(path)
            if fm.fileExists(atPath: cwd.path) { return cwd }
            return nil
        }

        guard let corpusRoot else { return nil }
        let direct = corpusRoot.appendingPathComponent(path)
        if fm.fileExists(atPath: direct.path) { return direct }

        let token = path.lowercased()
        let matches = CorpusDiscovery.files(in: corpusRoot).filter {
            $0.path.lowercased().contains(token) || $0.lastPathComponent.lowercased().contains(token)
        }
        return matches.sorted { $0.path < $1.path }.first
    }
}
