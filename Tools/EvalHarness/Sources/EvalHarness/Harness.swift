import Extract
import Foundation

public enum HarnessMode: String, Sendable {
    case survey
    case accuracy
    case compare
    case anchors
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
        runAnchors: Bool = true
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
                tableDetection: options.tableDetection
            )
            let summary = try await AccuracyRunner.run(
                files: files,
                rootForRelative: root,
                config: config,
                includeContent: options.includeContent
            )
            try ReportWriter.writeAccuracy(
                summary,
                outputDir: options.outputDir,
                configLabel: configLabel
            )
            messages.append(
                "Accuracy: overall \(String(format: "%.1f%%", summary.overallAccuracy * 100)) (\(summary.overallCorrect)/\(summary.overallTotal)); present-in-text \(String(format: "%.1f%%", summary.presentAccuracy * 100)); unpaired \(summary.unpaired); GT files \(summary.withGroundTruth)"
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
                "Compare \(a.name) vs \(b.name): overall Δ \(String(format: "%+.2f", summary.overallDeltaPP)) pp; changed files \(summary.changedFiles.count)"
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
    public static func findRepoRoot(from start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
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
