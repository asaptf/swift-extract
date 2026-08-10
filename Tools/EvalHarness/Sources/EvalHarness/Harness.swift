import Extract
import Foundation

public enum HarnessMode: String, Sendable {
    case survey
    case accuracy
    case compare
    case anchors
    /// Arm A normal budget vs Arm B forced chunking (same model / GT).
    case chunkMerge = "chunk-merge"
}

public struct HarnessOptions: Sendable {
    public var mode: HarnessMode
    public var corpus: URL?
    public var fixtures: URL?
    public var repoRoot: URL
    public var outputDir: URL
    public var backend: BackendKind
    public var modelId: String?
    public var tableDetection: TableDetectionMode
    public var anchorsFile: URL?
    public var includeContent: Bool
    public var configA: RunConfig?
    public var configB: RunConfig?
    public var runAnchors: Bool
    /// Soft budget for Arm A (chunk-merge mode). Default 12_000.
    public var chunkBudgetA: Int
    /// Soft budget for Arm B forced chunking (chunk-merge mode). Default 400.
    public var chunkBudgetB: Int
    /// Optional max files for expensive model runs (chunk-merge / accuracy smoke).
    public var fileLimit: Int?
    /// Accuracy-mode arithmetic invariant (`EvalInvoice`). Default `true`.
    /// Compare mode uses each arm's ``RunConfig/arithmeticInvariant`` instead.
    public var arithmeticInvariant: Bool

    public init(
        mode: HarnessMode,
        corpus: URL? = nil,
        fixtures: URL? = nil,
        repoRoot: URL,
        outputDir: URL,
        backend: BackendKind = .mock,
        modelId: String? = nil,
        tableDetection: TableDetectionMode = .automatic,
        anchorsFile: URL? = nil,
        includeContent: Bool = false,
        configA: RunConfig? = nil,
        configB: RunConfig? = nil,
        runAnchors: Bool = true,
        chunkBudgetA: Int = ChunkMergeRunner.defaultBudgetA,
        chunkBudgetB: Int = ChunkMergeRunner.defaultBudgetB,
        fileLimit: Int? = nil,
        arithmeticInvariant: Bool = true
    ) {
        self.mode = mode
        self.corpus = corpus
        self.fixtures = fixtures
        self.repoRoot = repoRoot
        self.outputDir = outputDir
        self.backend = backend
        self.modelId = modelId
        self.tableDetection = tableDetection
        self.anchorsFile = anchorsFile
        self.includeContent = includeContent
        self.configA = configA
        self.configB = configB
        self.runAnchors = runAnchors
        self.chunkBudgetA = chunkBudgetA
        self.chunkBudgetB = chunkBudgetB
        self.fileLimit = fileLimit
        self.arithmeticInvariant = arithmeticInvariant
    }
}

public struct HarnessResult: Sendable {
    public var exitCode: Int32
    public var messages: [String]
}

/// Top-level evaluation harness entry.
public enum Harness {
    @discardableResult
    public static func run(_ options: HarnessOptions) async throws -> HarnessResult {
        var messages: [String] = []
        var exitCode: Int32 = 0

        let files = collectFiles(options: options)
        messages.append("Files: \(files.count) under evaluation roots")

        let configLabel =
            "backend=\(options.backend.rawValue) tableDetection=\(TableDetectionParsing.label(options.tableDetection)) model=\(options.modelId ?? "-")"

        switch options.mode {
        case .survey:
            let root = options.corpus ?? options.fixtures ?? options.repoRoot
            let summary = await SurveyRunner.run(
                files: files,
                rootForRelative: root,
                tableDetection: options.tableDetection,
                includeContent: options.includeContent
            )
            try ReportWriter.writeSurvey(summary, outputDir: options.outputDir, configLabel: configLabel)
            messages.append(
                "Survey: \(summary.filesOK)/\(summary.filesTotal) ok; line-item-shaped \(summary.filesWithLineItemShaped)/\(summary.filesOK) (\(String(format: "%.1f%%", summary.lineItemShapedShare * 100)))"
            )

        case .accuracy:
            let root = options.corpus ?? options.fixtures ?? options.repoRoot
            let config = RunConfig(
                name: "accuracy",
                backend: options.backend,
                modelId: options.modelId,
                tableDetection: options.tableDetection,
                arithmeticInvariant: options.arithmeticInvariant
            )
            let summary = try await AccuracyRunner.run(
                files: files,
                rootForRelative: root,
                config: config,
                includeContent: options.includeContent
            )
            // Use full reportLabel so invariant mode is never silent in the report.
            try ReportWriter.writeAccuracy(
                summary,
                outputDir: options.outputDir,
                configLabel: config.reportLabel
            )
            let overallPct = String(format: "%.1f%%", summary.overallAccuracy * 100)
            let fiPct = String(format: "%.1f%%", summary.failureInclusiveAccuracy * 100)
            let paired = summary.scored + summary.hardFailures
            messages.append(
                "Accuracy: overall \(overallPct) (\(summary.overallCorrect)/\(summary.overallTotal)); "
                    + "failure-inclusive \(fiPct) (\(summary.failureInclusiveCorrect)/\(summary.failureInclusiveTotal)); "
                    + "hard failures \(summary.hardFailures)/\(paired) paired; "
                    + "unpaired \(summary.unpaired); GT files \(summary.withGroundTruth)"
            )

        case .compare:
            guard let a = options.configA, let b = options.configB else {
                throw CLIParseError.missingValue("--config-a / --config-b")
            }
            let root = options.corpus ?? options.fixtures ?? options.repoRoot
            let summary = try await ABCompareRunner.run(
                files: files,
                rootForRelative: root,
                configA: a,
                configB: b
            )
            try ReportWriter.writeCompare(summary, outputDir: options.outputDir)
            messages.append(
                "Compare \(a.name) vs \(b.name): overall Δ \(String(format: "%+.2f", summary.overallDeltaPP)) pp; failure-inclusive Δ \(String(format: "%+.2f", summary.failureInclusiveDeltaPP)) pp; hard failures A/B \(summary.hardFailuresA)/\(summary.hardFailuresB); changed files \(summary.changedFiles.count)"
            )
            messages.append("  A: \(a.reportLabel)")
            messages.append("  B: \(b.reportLabel)")

        case .chunkMerge:
            let root = options.corpus ?? options.fixtures ?? options.repoRoot
            let summary = try await ChunkMergeRunner.run(
                files: files,
                rootForRelative: root,
                backend: options.backend,
                modelId: options.modelId,
                tableDetection: options.tableDetection,
                budgetA: options.chunkBudgetA,
                budgetB: options.chunkBudgetB,
                limit: options.fileLimit,
                includeContent: options.includeContent
            )
            try ReportWriter.writeChunkMerge(summary, outputDir: options.outputDir)
            let oa =
                summary.overallA.total == 0
                ? 0 : Double(summary.overallA.correct) / Double(summary.overallA.total)
            let ob =
                summary.overallB.total == 0
                ? 0 : Double(summary.overallB.correct) / Double(summary.overallB.total)
            messages.append(
                "Chunk-merge: budget A=\(summary.budgetA) B=\(summary.budgetB); scored \(summary.scored); chunkedB \(summary.chunkedB); overall A \(String(format: "%.1f%%", oa * 100)) B \(String(format: "%.1f%%", ob * 100)); fail A/B \(summary.failuresA)/\(summary.failuresB); line-count exact A/B \(summary.lineCountExactA)/\(summary.lineCountExactB) of \(summary.lineCountScored)"
            )

        case .anchors:
            // anchors-only mode
            break
        }

        if options.runAnchors || options.mode == .anchors {
            let anchorsURL =
                options.anchorsFile
                ?? AnchorLoader.bundledAnchorsURL()
            guard let anchorsURL else {
                messages.append("Anchors: no anchors file found")
                exitCode = 1
                return HarnessResult(exitCode: exitCode, messages: messages)
            }
            let file = try AnchorLoader.load(from: anchorsURL)
            let anchorSummary = await AnchorRunner.run(
                anchors: file.anchors,
                repoRoot: options.repoRoot,
                corpusRoot: options.corpus,
                tableDetection: options.tableDetection
            )
            try ReportWriter.writeAnchors(anchorSummary, outputDir: options.outputDir)
            messages.append(
                "Anchors: \(anchorSummary.passed) passed, \(anchorSummary.failed) failed, \(anchorSummary.skipped) skipped"
            )
            for r in anchorSummary.results {
                for m in r.messages {
                    messages.append("  [\(r.status.rawValue)] \(r.id): \(m)")
                }
            }
            if anchorSummary.failed > 0 {
                exitCode = 1
            }
        }

        return HarnessResult(exitCode: exitCode, messages: messages)
    }

    private static func collectFiles(options: HarnessOptions) -> [URL] {
        var urls: [URL] = []
        if let fixtures = options.fixtures {
            urls.append(contentsOf: CorpusDiscovery.files(in: fixtures))
        }
        if let corpus = options.corpus {
            urls.append(contentsOf: CorpusDiscovery.files(in: corpus))
        }
        // Dedup by path
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    /// Walk up from `start` looking for Package.swift + fixtures/ (repo root).
    public static func findRepoRoot(
        from start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    )
        -> URL
    {
        var dir = start.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<12 {
            let pkg = dir.appendingPathComponent("Package.swift")
            let fixtures = dir.appendingPathComponent("fixtures")
            if fm.fileExists(atPath: pkg.path), fm.fileExists(atPath: fixtures.path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return start
    }
}
