import Extract
import Foundation

// MARK: - Records

/// One arm of the chunk-merge experiment for a single file.
public struct ChunkMergeArmRecord: Sendable {
    public var name: String
    public var softBudget: Int
    public var chunksUsed: Int
    public var attempts: Int
    public var fieldScores: [FieldScore]
    public var extractionError: String?
    public var extractionSeconds: Double
    public var predictedLineItemCount: Int
    public var truthLineItemCount: Int
    public var lineItemCountDelta: Int
    /// Predicted descriptions (short) for loss/duplication analysis.
    public var predictedDescriptions: [String]
    public var truthDescriptions: [String]
    /// Count of predicted descriptions that appear more than once (exact normalize).
    public var duplicatePredictedDescriptions: Int
    /// Truth descriptions with no match in predicted (lost items).
    public var lostDescriptions: [String]
    /// Predicted descriptions with no match in truth (extra / hallucinated / split fragments).
    public var extraDescriptions: [String]
    public var signalsFieldCount: Int
    public var signalsWithProvenance: Int
    public var groundingCounts: [String: Int]
    /// Paths whose grounding is verbatim/normalized but provenance is nil (geometry miss).
    public var groundedWithoutProvenance: Int
    /// Sample of field paths with non-nil provenance (first few).
    public var sampleProvenancePaths: [String]
    /// Times `validateInvariants` ran a full arithmetic check this arm.
    public var invariantChecks: Int
    /// Times the arithmetic check failed (triggers repair when retries remain).
    public var invariantViolations: Int
    /// Times the check was skipped (missing pieces).
    public var invariantSkips: Int
    /// True when at least one invariant violation was observed this arm.
    public var invariantTriggered: Bool
    /// True when `validationFailed` and lastError was an invariant error.
    public var invariantValidationFailed: Bool
}

/// Per-file paired A vs B measurement.
public struct ChunkMergeFileRecord: Sendable {
    public var file: String
    public var relativePath: String
    public var characterCount: Int
    public var pageCountEstimate: Int
    public var tableCount: Int
    public var tablePageIndices: [Int]
    public var hasGroundTruth: Bool
    public var paired: Bool
    public var unpairedReason: String?
    public var armA: ChunkMergeArmRecord?
    public var armB: ChunkMergeArmRecord?
    /// Heuristic notes: hard-split mid-line risk, table/chunk mismatch.
    public var diagnostics: [String]
}

public struct ChunkMergeSummary: Sendable {
    public var budgetA: Int
    public var budgetB: Int
    public var backendLabel: String
    public var records: [ChunkMergeFileRecord]
    public var filesTotal: Int
    public var withGroundTruth: Int
    public var unpaired: Int
    public var scored: Int
    public var chunkedB: Int
    public var failuresA: Int
    public var failuresB: Int
    public var meanAttemptsA: Double
    public var meanAttemptsB: Double
    public var meanChunksA: Double
    public var meanChunksB: Double
    public var overallA: (correct: Int, total: Int)
    public var overallB: (correct: Int, total: Int)
    public var perFieldA: [String: (correct: Int, total: Int)]
    public var perFieldB: [String: (correct: Int, total: Int)]
    public var headerFieldsA: (correct: Int, total: Int)
    public var headerFieldsB: (correct: Int, total: Int)
    public var lineDescA: (correct: Int, total: Int)
    public var lineDescB: (correct: Int, total: Int)
    public var lineAmtA: (correct: Int, total: Int)
    public var lineAmtB: (correct: Int, total: Int)
    public var lineCountExactA: Int
    public var lineCountExactB: Int
    public var lineCountScored: Int
    public var lostItemsTotalB: Int
    public var extraItemsTotalB: Int
    public var dupItemsTotalB: Int
    public var provenanceRateA: Double
    public var provenanceRateB: Double
    public var groundedWithoutProvA: Int
    public var groundedWithoutProvB: Int
    /// Files (paired) where Arm A/B saw ≥1 invariant violation during extraction.
    public var invariantTriggeredA: Int
    public var invariantTriggeredB: Int
    /// Of triggered files: extraction succeeded (repair recovered enough to return a value).
    public var invariantRecoveredA: Int
    public var invariantRecoveredB: Int
    /// Of triggered files: ended in `validationFailed` with an invariant lastError.
    public var invariantStillFailedA: Int
    public var invariantStillFailedB: Int
    /// Of recovered files: grandTotal field scored correct vs GT.
    public var invariantRecoveredGrandTotalCorrectA: Int
    public var invariantRecoveredGrandTotalCorrectB: Int
    /// Wall-clock sums / means for paired arms (seconds).
    public var sumSecondsA: Double
    public var sumSecondsB: Double
    public var meanSecondsA: Double
    public var meanSecondsB: Double
}

// MARK: - Runner

public enum ChunkMergeRunner {
    public static let defaultBudgetA = 12_000
    /// Default forced-chunk budget: ~3–5 chunks on median ~1.7k char corpus invoices.
    public static let defaultBudgetB = 400

    public static let headerFieldNames: Set<String> = [
        "invoiceNumber", "issueDate", "currency", "sellerName", "grandTotal", "taxTotal",
    ]

    public static func run(
        files: [URL],
        rootForRelative: URL,
        backend: BackendKind,
        modelId: String?,
        tableDetection: TableDetectionMode,
        budgetA: Int = defaultBudgetA,
        budgetB: Int = defaultBudgetB,
        temperature: Double = 0,
        maxRetries: Int = 1,
        limit: Int? = nil,
        includeContent: Bool = false
    ) async throws -> ChunkMergeSummary {
        _ = includeContent
        let configA = RunConfig(
            name: "A-baseline",
            backend: backend,
            modelId: modelId,
            tableDetection: tableDetection,
            temperature: temperature,
            maxRetries: maxRetries,
            softContextCharacterBudget: budgetA
        )
        let configB = RunConfig(
            name: "B-chunked",
            backend: backend,
            modelId: modelId,
            tableDetection: tableDetection,
            temperature: temperature,
            maxRetries: maxRetries,
            softContextCharacterBudget: budgetB
        )

        let session = try configA.makeSession()
        let optsA = configA.extractionOptions
        let optsB = configB.extractionOptions

        var selected = files
        if let limit, limit > 0, limit < selected.count {
            selected = Array(selected.prefix(limit))
        }

        var records: [ChunkMergeFileRecord] = []
        for (idx, url) in selected.enumerated() {
            fputs(
                "chunk-merge [\(idx + 1)/\(selected.count)] \(url.lastPathComponent)\n",
                stderr
            )
            let rec = await scoreFile(
                url: url,
                rootForRelative: rootForRelative,
                session: session,
                optsA: optsA,
                optsB: optsB,
                budgetA: budgetA,
                budgetB: budgetB
            )
            records.append(rec)
        }
        records.sort { $0.relativePath < $1.relativePath }
        return reduce(
            records,
            budgetA: budgetA,
            budgetB: budgetB,
            backendLabel:
                "backend=\(backend.rawValue) model=\(modelId ?? "-") tables=\(TableDetectionParsing.label(tableDetection)) temp=\(temperature) retries=\(maxRetries)"
        )
    }

    // MARK: - Per file

    private static func scoreFile(
        url: URL,
        rootForRelative: URL,
        session: ExtractionSession,
        optsA: ExtractionOptions,
        optsB: ExtractionOptions,
        budgetA: Int,
        budgetB: Int
    ) async -> ChunkMergeFileRecord {
        let relative = SurveyRunner.relativePath(url, root: rootForRelative)

        let inspection: DocumentInspection
        do {
            inspection = try await Extract.inspect(url, tableDetection: optsA.tableDetection)
        } catch {
            return ChunkMergeFileRecord(
                file: url.path,
                relativePath: relative,
                characterCount: 0,
                pageCountEstimate: 0,
                tableCount: 0,
                tablePageIndices: [],
                hasGroundTruth: false,
                paired: false,
                unpairedReason: nil,
                armA: nil,
                armB: nil,
                diagnostics: ["inspect failed: \(error)"]
            )
        }

        let pageCount = max(1, estimatePageCount(inspection.fullText))
        let tablePages = inspection.tables.map(\.pageIndex).sorted()
        var diagnostics = diagnoseChunkLayout(
            fullText: inspection.fullText,
            characterCount: inspection.characterCount,
            tables: inspection.tables,
            budgetB: budgetB
        )

        var truth: InvoiceGroundTruth?
        if url.pathExtension.lowercased() == "pdf" {
            truth = try? FacturXExtractor.groundTruth(fromPDF: url)
        }

        guard let truth else {
            // Still run both arms for chunksUsed / failure stats on non-GT files? Skip model cost.
            return ChunkMergeFileRecord(
                file: url.path,
                relativePath: relative,
                characterCount: inspection.characterCount,
                pageCountEstimate: pageCount,
                tableCount: inspection.tables.count,
                tablePageIndices: tablePages,
                hasGroundTruth: false,
                paired: false,
                unpairedReason: nil,
                armA: nil,
                armB: nil,
                diagnostics: diagnostics + ["no Factur-X ground truth — skipped extraction"]
            )
        }

        guard FieldScoring.isPaired(truth: truth, documentText: inspection.fullText) else {
            return ChunkMergeFileRecord(
                file: url.path,
                relativePath: relative,
                characterCount: inspection.characterCount,
                pageCountEstimate: pageCount,
                tableCount: inspection.tables.count,
                tablePageIndices: tablePages,
                hasGroundTruth: true,
                paired: false,
                unpairedReason:
                    "pairing token '\(truth.pairingToken ?? "?")' not found in extracted text",
                armA: nil,
                armB: nil,
                diagnostics: diagnostics
            )
        }

        let armA = await extractArm(
            name: "A-baseline",
            url: url,
            session: session,
            options: optsA,
            softBudget: budgetA,
            truth: truth,
            documentText: inspection.fullText
        )
        let armB = await extractArm(
            name: "B-chunked",
            url: url,
            session: session,
            options: optsB,
            softBudget: budgetB,
            truth: truth,
            documentText: inspection.fullText
        )

        if armB.chunksUsed <= 1, inspection.characterCount > budgetB {
            diagnostics.append(
                "WARNING: charCount \(inspection.characterCount) > budgetB \(budgetB) but chunksUsed=\(armB.chunksUsed)"
            )
        }
        if armB.chunksUsed > 1 {
            diagnostics.append("Arm B used \(armB.chunksUsed) chunks (budget \(budgetB))")
        }

        return ChunkMergeFileRecord(
            file: url.path,
            relativePath: relative,
            characterCount: inspection.characterCount,
            pageCountEstimate: pageCount,
            tableCount: inspection.tables.count,
            tablePageIndices: tablePages,
            hasGroundTruth: true,
            paired: true,
            unpairedReason: nil,
            armA: armA,
            armB: armB,
            diagnostics: diagnostics
        )
    }

    private static func extractArm(
        name: String,
        url: URL,
        session: ExtractionSession,
        options: ExtractionOptions,
        softBudget: Int,
        truth: InvoiceGroundTruth,
        documentText: String
    ) async -> ChunkMergeArmRecord {
        let truthDescs = truth.lineItems.compactMap(\.description).filter { !$0.isEmpty }
        let truthCount = truth.lineItems.count
        EvalInvoice.InvariantProbe.reset()
        let start = ContinuousClock.now
        do {
            // Guard against unbounded MLX generation (observed multi-10-minute hangs).
            let result = try await withTimeout(seconds: 240) {
                try await Extract.detailed(
                    from: .fileURL(url),
                    as: EvalInvoice.self,
                    using: session,
                    options: options
                )
            }
            let elapsed = seconds(since: start)
            let probe = EvalInvoice.InvariantProbe.snapshot()
            let predicted = result.value
            let predLines = predicted.lineItems ?? []
            let predDescs = predLines.compactMap(\.description)
            let card = FieldScoring.score(
                file: url.lastPathComponent,
                truth: truth,
                predicted: predicted,
                documentText: documentText
            )
            let lost = lostDescriptions(truth: truthDescs, predicted: predDescs)
            let extra = extraDescriptions(truth: truthDescs, predicted: predDescs)
            let dups = duplicateCount(predDescs)

            var groundingCounts: [String: Int] = [:]
            var withProv = 0
            var groundedNoProv = 0
            var sampleProv: [String] = []
            for f in result.signals.fields {
                groundingCounts[f.grounding.rawValue, default: 0] += 1
                if f.provenance != nil {
                    withProv += 1
                    if sampleProv.count < 6 {
                        sampleProv.append(f.path)
                    }
                } else if f.grounding == .verbatim || f.grounding == .normalized {
                    groundedNoProv += 1
                }
            }

            return ChunkMergeArmRecord(
                name: name,
                softBudget: softBudget,
                chunksUsed: result.chunksUsed,
                attempts: result.attempts,
                fieldScores: card.fields,
                extractionError: nil,
                extractionSeconds: elapsed,
                predictedLineItemCount: predLines.count,
                truthLineItemCount: truthCount,
                lineItemCountDelta: predLines.count - truthCount,
                predictedDescriptions: predDescs,
                truthDescriptions: truthDescs,
                duplicatePredictedDescriptions: dups,
                lostDescriptions: lost,
                extraDescriptions: extra,
                signalsFieldCount: result.signals.fields.count,
                signalsWithProvenance: withProv,
                groundingCounts: groundingCounts,
                groundedWithoutProvenance: groundedNoProv,
                sampleProvenancePaths: sampleProv,
                invariantChecks: probe.checks,
                invariantViolations: probe.violations,
                invariantSkips: probe.skips,
                invariantTriggered: probe.violations > 0,
                invariantValidationFailed: false
            )
        } catch {
            let elapsed = seconds(since: start)
            let probe = EvalInvoice.InvariantProbe.snapshot()
            let attempts: Int
            var invariantFailed = false
            if let ee = error as? ExtractionError,
                case .validationFailed(let a, let last, _) = ee
            {
                attempts = a
                invariantFailed = last is InvariantValidationError
            } else {
                attempts = 0
            }
            return ChunkMergeArmRecord(
                name: name,
                softBudget: softBudget,
                chunksUsed: 0,
                attempts: attempts,
                fieldScores: [],
                extractionError: String(describing: error),
                extractionSeconds: elapsed,
                predictedLineItemCount: 0,
                truthLineItemCount: truthCount,
                lineItemCountDelta: -truthCount,
                predictedDescriptions: [],
                truthDescriptions: truthDescs,
                duplicatePredictedDescriptions: 0,
                lostDescriptions: truthDescs,
                extraDescriptions: [],
                signalsFieldCount: 0,
                signalsWithProvenance: 0,
                groundingCounts: [:],
                groundedWithoutProvenance: 0,
                sampleProvenancePaths: [],
                invariantChecks: probe.checks,
                invariantViolations: probe.violations,
                invariantSkips: probe.skips,
                invariantTriggered: probe.violations > 0 || invariantFailed,
                invariantValidationFailed: invariantFailed
            )
        }
    }

    // MARK: - Timeout

    private enum ArmTimeoutError: Error, CustomStringConvertible {
        case exceeded(seconds: Int)
        var description: String {
            switch self {
            case .exceeded(let s): return "arm extraction timed out after \(s)s"
            }
        }
    }

    /// Race `operation` against a wall-clock limit. Cancellation of MLX work is best-effort;
    /// the timeout still unblocks the harness so one file cannot hang the full run.
    private static func withTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ArmTimeoutError.exceeded(seconds: seconds)
            }
            guard let first = try await group.next() else {
                throw ArmTimeoutError.exceeded(seconds: seconds)
            }
            group.cancelAll()
            return first
        }
    }

    // MARK: - Line-item set comparison

    private static func descriptionsMatch(_ a: String, _ b: String) -> Bool {
        if FieldNormalization.textsEqual(a, b) { return true }
        return FieldNormalization.textContains(a, needle: b)
            || FieldNormalization.textContains(b, needle: a)
    }

    private static func lostDescriptions(truth: [String], predicted: [String]) -> [String] {
        truth.filter { t in
            !predicted.contains { descriptionsMatch($0, t) }
        }
    }

    private static func extraDescriptions(truth: [String], predicted: [String]) -> [String] {
        predicted.filter { p in
            !truth.contains { descriptionsMatch(p, $0) }
        }
    }

    private static func duplicateCount(_ descs: [String]) -> Int {
        var seen: [String: Int] = [:]
        for d in descs {
            let key = FieldNormalization.normalizeText(d)
            seen[key, default: 0] += 1
        }
        return seen.values.filter { $0 > 1 }.reduce(0) { $0 + ($1 - 1) }
    }

    // MARK: - Diagnostics (no model)

    /// Estimate page count from linearised text markers.
    private static func estimatePageCount(_ text: String) -> Int {
        let markers = text.components(separatedBy: "--- Page ").count - 1
        return max(1, markers)
    }

    /// Heuristic layout diagnostics for forced budget (does not call the model).
    ///
    /// Mirrors the library’s *intent*: page-preferring character budgets, then hard
    /// splits that prefer newline → whitespace within a window (same idea as
    /// `ExtractedDocument.hardSplit`). Uses linearised fullText so exact chunk
    /// boundaries may differ slightly from block-level splits.
    static func diagnoseChunkLayout(
        fullText: String,
        characterCount: Int,
        tables: [ExtractedTable],
        budgetB: Int
    ) -> [String] {
        var notes: [String] = []
        guard budgetB > 0 else { return notes }

        let pages = splitPages(fullText)
        if characterCount <= budgetB {
            notes.append("document fits in one chunk under budget \(budgetB) (no forced merge)")
            return notes
        }

        // Page-aware packing + hard split oversized pages (boundary-aware).
        var chunkTexts: [String] = []
        var current = ""
        let boundaryWindow = min(80, budgetB)
        for page in pages {
            if page.count > budgetB {
                if !current.isEmpty {
                    chunkTexts.append(current)
                    current = ""
                }
                var start = page.startIndex
                while start < page.endIndex {
                    let hardEnd =
                        page.index(start, offsetBy: budgetB, limitedBy: page.endIndex)
                        ?? page.endIndex
                    let end: String.Index
                    if hardEnd == page.endIndex {
                        end = hardEnd
                    } else {
                        end = preferredHardSplitEnd(
                            in: page,
                            start: start,
                            hardEnd: hardEnd,
                            window: boundaryWindow
                        )
                    }
                    let slice = String(page[start..<end])
                    // Residual mid-token cut only when no boundary was available.
                    if end < page.endIndex, end == hardEnd {
                        let cutChar = page[page.index(before: end)]
                        let nextChar = page[end]
                        let midWord =
                            (cutChar.isLetter && nextChar.isLetter)
                            || (cutChar.isNumber && nextChar.isNumber)
                        if midWord {
                            let leftCtx = String(page.prefix(upTo: end).suffix(24))
                                .replacingOccurrences(of: "\n", with: " ")
                            let rightCtx = String(page[end...].prefix(24))
                                .replacingOccurrences(of: "\n", with: " ")
                            notes.append(
                                "hard-split mid-token near …\(leftCtx)|\(rightCtx)…"
                            )
                        }
                    }
                    chunkTexts.append(slice)
                    start = end
                }
            } else if current.count + page.count > budgetB {
                if !current.isEmpty { chunkTexts.append(current) }
                current = page
            } else {
                if current.isEmpty {
                    current = page
                } else {
                    current += "\n\n" + page
                }
            }
        }
        if !current.isEmpty { chunkTexts.append(current) }

        notes.append(
            "estimated chunks at budget \(budgetB): \(chunkTexts.count) (charCount=\(characterCount), pages=\(pages.count))"
        )

        // Table assignment risk (mirrors Extract.assignTablesToChunks: cell-text containment).
        // A table attaches only to chunks that contain every non-empty cell string.
        if !tables.isEmpty {
            let pageIndices = Set(0..<pages.count)
            for table in tables {
                let p = table.pageIndex
                guard pageIndices.contains(p) || pages.count == 1 else {
                    notes.append(
                        "table pageIndex=\(p) outside estimated pages 0..<\(pages.count)"
                    )
                    continue
                }
                let pageText = pages.indices.contains(p) ? pages[p] : fullText
                let cells = table.cells.map(\.text).filter {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                guard !cells.isEmpty else { continue }
                let missingOnPage = cells.filter { !pageText.contains($0) }
                if !missingOnPage.isEmpty {
                    notes.append(
                        "table on page \(p): \(missingOnPage.count)/\(cells.count) non-empty cells not found as substrings of page text (OCR/join drift)"
                    )
                }
                // Among estimated hard-split slices, count how many would receive the table.
                let matchingChunks = chunkTexts.filter { slice in
                    cells.allSatisfy { slice.contains($0) }
                }.count
                if matchingChunks == 0 {
                    notes.append(
                        "table page \(p): cell-text containment matches 0 estimated chunks (table omitted from all prompts)"
                    )
                } else if matchingChunks > 1 {
                    notes.append(
                        "table page \(p): cell-text containment matches \(matchingChunks) estimated chunks"
                    )
                }
            }
        }

        return notes
    }

    /// Prefer newline, then whitespace, near `hardEnd` (library hard-split policy).
    private static func preferredHardSplitEnd(
        in text: String,
        start: String.Index,
        hardEnd: String.Index,
        window: Int
    ) -> String.Index {
        let backLo = text.index(hardEnd, offsetBy: -window, limitedBy: start) ?? start
        let forwardHi =
            text.index(hardEnd, offsetBy: window, limitedBy: text.endIndex) ?? text.endIndex

        if let idx = lastBoundaryIndex(in: text, range: backLo..<hardEnd, afterStart: start, {
            $0.isNewline
        }) {
            return idx
        }
        if let idx = firstBoundaryIndex(in: text, range: hardEnd..<forwardHi, { $0.isNewline }) {
            return idx
        }
        if let idx = lastBoundaryIndex(in: text, range: backLo..<hardEnd, afterStart: start, {
            $0.isWhitespace
        }) {
            return idx
        }
        if let idx = firstBoundaryIndex(in: text, range: hardEnd..<forwardHi, { $0.isWhitespace }) {
            return idx
        }
        return hardEnd
    }

    private static func lastBoundaryIndex(
        in text: String,
        range: Range<String.Index>,
        afterStart: String.Index,
        _ predicate: (Character) -> Bool
    ) -> String.Index? {
        var best: String.Index?
        var i = range.lowerBound
        while i < range.upperBound {
            let ch = text[i]
            let next = text.index(after: i)
            if predicate(ch), next > afterStart {
                best = next
            }
            i = next
        }
        return best
    }

    private static func firstBoundaryIndex(
        in text: String,
        range: Range<String.Index>,
        _ predicate: (Character) -> Bool
    ) -> String.Index? {
        var i = range.lowerBound
        while i < range.upperBound {
            let ch = text[i]
            let next = text.index(after: i)
            if predicate(ch) {
                return next
            }
            i = next
        }
        return nil
    }

    private static func splitPages(_ fullText: String) -> [String] {
        // fullText uses "--- Page N ---" headers for multi-page docs.
        if !fullText.contains("--- Page ") {
            return [fullText]
        }
        var parts: [String] = []
        let ns = fullText as NSString
        let regex = try? NSRegularExpression(pattern: #"(?m)^--- Page \d+ ---\n?"#)
        guard let regex else { return [fullText] }
        let matches = regex.matches(
            in: fullText,
            range: NSRange(location: 0, length: ns.length)
        )
        if matches.isEmpty { return [fullText] }
        // Text before first marker (unpaged prefix).
        if matches[0].range.location > 0 {
            let prefix = ns.substring(to: matches[0].range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { parts.append(prefix) }
        }
        for (i, m) in matches.enumerated() {
            let start = m.range.location + m.range.length
            let end =
                i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            if start < end {
                parts.append(ns.substring(with: NSRange(location: start, length: end - start)))
            }
        }
        return parts.isEmpty ? [fullText] : parts
    }

    // MARK: - Reduce

    private static func reduce(
        _ records: [ChunkMergeFileRecord],
        budgetA: Int,
        budgetB: Int,
        backendLabel: String
    ) -> ChunkMergeSummary {
        let gt = records.filter(\.hasGroundTruth)
        let paired = gt.filter(\.paired)
        let scored = paired.filter { $0.armA?.extractionError == nil || $0.armB != nil }

        var overallA = (0, 0)
        var overallB = (0, 0)
        var perA: [String: (Int, Int)] = [:]
        var perB: [String: (Int, Int)] = [:]
        var headerA = (0, 0)
        var headerB = (0, 0)
        var descA = (0, 0)
        var descB = (0, 0)
        var amtA = (0, 0)
        var amtB = (0, 0)
        var lineExactA = 0
        var lineExactB = 0
        var lineScored = 0
        var lostB = 0
        var extraB = 0
        var dupB = 0
        var failA = 0
        var failB = 0
        var attA: [Int] = []
        var attB: [Int] = []
        var chA: [Int] = []
        var chB: [Int] = []
        var chunkedB = 0
        var provFieldsA = 0
        var provOkA = 0
        var provFieldsB = 0
        var provOkB = 0
        var gwpA = 0
        var gwpB = 0
        var invTrigA = 0
        var invTrigB = 0
        var invRecA = 0
        var invRecB = 0
        var invFailA = 0
        var invFailB = 0
        var invGTOkA = 0
        var invGTOkB = 0
        var secA: [Double] = []
        var secB: [Double] = []

        for rec in paired {
            if let a = rec.armA {
                if a.extractionError != nil { failA += 1 }
                attA.append(a.attempts)
                chA.append(a.chunksUsed)
                secA.append(a.extractionSeconds)
                provFieldsA += a.signalsFieldCount
                provOkA += a.signalsWithProvenance
                gwpA += a.groundedWithoutProvenance
                if a.invariantTriggered {
                    invTrigA += 1
                    if a.extractionError == nil {
                        invRecA += 1
                        if a.fieldScores.first(where: { $0.field == "grandTotal" })?.correct
                            == true
                        {
                            invGTOkA += 1
                        }
                    }
                    if a.invariantValidationFailed { invFailA += 1 }
                }
                for f in a.fieldScores {
                    overallA.1 += 1
                    if f.correct { overallA.0 += 1 }
                    var p = perA[f.field, default: (0, 0)]
                    p.1 += 1
                    if f.correct { p.0 += 1 }
                    perA[f.field] = p
                    accumulateRole(f, header: &headerA, desc: &descA, amt: &amtA)
                }
                if a.extractionError == nil {
                    lineScored += 1
                    if a.predictedLineItemCount == a.truthLineItemCount { lineExactA += 1 }
                }
            }
            if let b = rec.armB {
                if b.extractionError != nil { failB += 1 }
                attB.append(b.attempts)
                chB.append(b.chunksUsed)
                secB.append(b.extractionSeconds)
                if b.chunksUsed > 1 { chunkedB += 1 }
                provFieldsB += b.signalsFieldCount
                provOkB += b.signalsWithProvenance
                gwpB += b.groundedWithoutProvenance
                lostB += b.lostDescriptions.count
                extraB += b.extraDescriptions.count
                dupB += b.duplicatePredictedDescriptions
                if b.invariantTriggered {
                    invTrigB += 1
                    if b.extractionError == nil {
                        invRecB += 1
                        if b.fieldScores.first(where: { $0.field == "grandTotal" })?.correct
                            == true
                        {
                            invGTOkB += 1
                        }
                    }
                    if b.invariantValidationFailed { invFailB += 1 }
                }
                for f in b.fieldScores {
                    overallB.1 += 1
                    if f.correct { overallB.0 += 1 }
                    var p = perB[f.field, default: (0, 0)]
                    p.1 += 1
                    if f.correct { p.0 += 1 }
                    perB[f.field] = p
                    accumulateRole(f, header: &headerB, desc: &descB, amt: &amtB)
                }
                if b.extractionError == nil,
                    b.predictedLineItemCount == b.truthLineItemCount
                {
                    lineExactB += 1
                }
            }
        }

        // lineExactB counted only when A side also scored — fix: recount lineExactB over same set
        lineExactB = 0
        lineExactA = 0
        lineScored = 0
        for rec in paired {
            guard let a = rec.armA, let b = rec.armB,
                a.extractionError == nil, b.extractionError == nil
            else { continue }
            lineScored += 1
            if a.predictedLineItemCount == a.truthLineItemCount { lineExactA += 1 }
            if b.predictedLineItemCount == b.truthLineItemCount { lineExactB += 1 }
        }

        func mean(_ xs: [Int]) -> Double {
            xs.isEmpty ? 0 : Double(xs.reduce(0, +)) / Double(xs.count)
        }
        func meanD(_ xs: [Double]) -> Double {
            xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
        }

        return ChunkMergeSummary(
            budgetA: budgetA,
            budgetB: budgetB,
            backendLabel: backendLabel,
            records: records,
            filesTotal: records.count,
            withGroundTruth: gt.count,
            unpaired: gt.filter { !$0.paired }.count,
            scored: scored.count,
            chunkedB: chunkedB,
            failuresA: failA,
            failuresB: failB,
            meanAttemptsA: mean(attA),
            meanAttemptsB: mean(attB),
            meanChunksA: mean(chA),
            meanChunksB: mean(chB),
            overallA: overallA,
            overallB: overallB,
            perFieldA: perA,
            perFieldB: perB,
            headerFieldsA: headerA,
            headerFieldsB: headerB,
            lineDescA: descA,
            lineDescB: descB,
            lineAmtA: amtA,
            lineAmtB: amtB,
            lineCountExactA: lineExactA,
            lineCountExactB: lineExactB,
            lineCountScored: lineScored,
            lostItemsTotalB: lostB,
            extraItemsTotalB: extraB,
            dupItemsTotalB: dupB,
            provenanceRateA: provFieldsA == 0 ? 0 : Double(provOkA) / Double(provFieldsA),
            provenanceRateB: provFieldsB == 0 ? 0 : Double(provOkB) / Double(provFieldsB),
            groundedWithoutProvA: gwpA,
            groundedWithoutProvB: gwpB,
            invariantTriggeredA: invTrigA,
            invariantTriggeredB: invTrigB,
            invariantRecoveredA: invRecA,
            invariantRecoveredB: invRecB,
            invariantStillFailedA: invFailA,
            invariantStillFailedB: invFailB,
            invariantRecoveredGrandTotalCorrectA: invGTOkA,
            invariantRecoveredGrandTotalCorrectB: invGTOkB,
            sumSecondsA: secA.reduce(0, +),
            sumSecondsB: secB.reduce(0, +),
            meanSecondsA: meanD(secA),
            meanSecondsB: meanD(secB)
        )
    }

    private static func accumulateRole(
        _ f: FieldScore,
        header: inout (Int, Int),
        desc: inout (Int, Int),
        amt: inout (Int, Int)
    ) {
        if headerFieldNames.contains(f.field) {
            header.1 += 1
            if f.correct { header.0 += 1 }
        } else if f.field.contains(".description") {
            desc.1 += 1
            if f.correct { desc.0 += 1 }
        } else if f.field.contains(".lineTotal") {
            amt.1 += 1
            if f.correct { amt.0 += 1 }
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}
