import EvalHarness
import Extract
import Foundation

@main
struct ExtractEvalMain {
    static func main() async {
        do {
            let code = try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            exit(code)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(2)
        }
    }

    static func run(arguments: [String]) async throws -> Int32 {
        if arguments.contains("-h") || arguments.contains("--help") || arguments.isEmpty {
            print(usage)
            return arguments.isEmpty ? 2 : 0
        }

        var mode: HarnessMode?
        var corpus: String?
        var fixtures: String?
        var output = "eval-out"
        var backend = "mock"
        var modelId: String?
        var tableDetection = "automatic"
        var anchors: String?
        var includeContent = false
        var runAnchors = true
        var configASpec: String?
        var configBSpec: String?
        var repoRootOverride: String?

        var args = arguments
        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "--mode":
                let rawMode = try take(&args, for: arg)
                guard let parsed = HarnessMode(rawValue: rawMode) else {
                    throw CLIParseError.invalidMode(rawMode)
                }
                mode = parsed
            case "--corpus":
                corpus = try take(&args, for: arg)
            case "--fixtures":
                fixtures = try take(&args, for: arg)
            case "--output", "-o":
                output = try take(&args, for: arg)
            case "--backend":
                backend = try take(&args, for: arg)
            case "--model":
                modelId = try take(&args, for: arg)
            case "--table-detection":
                tableDetection = try take(&args, for: arg)
            case "--anchors":
                anchors = try take(&args, for: arg)
            case "--include-content":
                includeContent = true
            case "--no-anchors":
                runAnchors = false
            case "--config-a":
                configASpec = try take(&args, for: arg)
            case "--config-b":
                configBSpec = try take(&args, for: arg)
            case "--repo-root":
                repoRootOverride = try take(&args, for: arg)
            default:
                if arg.hasPrefix("-") {
                    throw CLIParseError.unknownOption(arg)
                }
                throw CLIParseError.unknownOption(arg)
            }
        }

        guard let mode else {
            throw CLIParseError.missingValue("--mode")
        }

        let repoRoot: URL
        if let repoRootOverride {
            repoRoot = URL(fileURLWithPath: repoRootOverride)
        } else {
            repoRoot = Harness.findRepoRoot()
        }

        let corpusURL = CorpusDiscovery.resolveCorpusPath(cliValue: corpus)
        let fixturesURL: URL?
        if let fixtures {
            fixturesURL = URL(fileURLWithPath: fixtures)
        } else if mode != .compare {
            // Default smoke root: repo fixtures when no explicit corpus-only intent.
            let def = repoRoot.appendingPathComponent("fixtures")
            fixturesURL = FileManager.default.fileExists(atPath: def.path) ? def : nil
        } else {
            fixturesURL = nil
        }

        if corpusURL == nil && fixturesURL == nil && mode != .anchors {
            fputs(
                "error: no inputs. Pass --corpus, set EXTRACT_EVAL_CORPUS, or ensure fixtures/ exists.\n",
                stderr
            )
            return 2
        }

        let backendKind = try BackendFactory.parseBackend(backend)
        let tableMode = try TableDetectionParsing.parse(tableDetection)

        var configA: RunConfig?
        var configB: RunConfig?
        if mode == .compare {
            configA = try parseConfigSpec(configASpec, defaultName: "A")
            configB = try parseConfigSpec(configBSpec, defaultName: "B")
        }

        let options = HarnessOptions(
            mode: mode,
            corpus: corpusURL,
            fixtures: fixturesURL,
            repoRoot: repoRoot,
            outputDir: URL(fileURLWithPath: output),
            backend: backendKind,
            modelId: modelId,
            tableDetection: tableMode,
            anchorsFile: anchors.map { URL(fileURLWithPath: $0) },
            includeContent: includeContent,
            configA: configA,
            configB: configB,
            runAnchors: runAnchors || mode == .anchors
        )

        let result = try await Harness.run(options)
        for m in result.messages {
            print(m)
        }
        print("Reports written to \(options.outputDir.path)")
        return result.exitCode
    }

    /// Parse `name:backend=mock,tableDetection=off,model=…`
    static func parseConfigSpec(_ raw: String?, defaultName: String) throws -> RunConfig {
        guard let raw, !raw.isEmpty else {
            throw CLIParseError.missingValue("--config-a / --config-b")
        }
        var name = defaultName
        var backend = BackendKind.mock
        var modelId: String?
        var tableDetection = TableDetectionMode.automatic
        var rest = raw
        if let colon = raw.firstIndex(of: ":") {
            name = String(raw[..<colon])
            rest = String(raw[raw.index(after: colon)...])
        }
        for part in rest.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            switch kv[0].lowercased() {
            case "backend":
                backend = try BackendFactory.parseBackend(kv[1])
            case "model", "modelid":
                modelId = kv[1]
            case "tabledetection", "table-detection", "tables":
                tableDetection = try TableDetectionParsing.parse(kv[1])
            default:
                break
            }
        }
        return RunConfig(
            name: name,
            backend: backend,
            modelId: modelId,
            tableDetection: tableDetection
        )
    }

    static func take(_ args: inout [String], for option: String) throws -> String {
        guard let v = args.first else { throw CLIParseError.missingValue(option) }
        args.removeFirst()
        return v
    }

    static var usage: String {
        """
        extract-eval — evaluation harness for swift-extract

        Usage:
          extract-eval --mode survey|accuracy|compare|anchors [options]

        Modes:
          survey     Ingest only: timing, char counts, OCR fallback, table shapes/density
          accuracy   Extract + score against Factur-X/ZUGFeRD ground truth
          compare    A/B two named configs over the same files
          anchors    Evaluate named anchor checks only

        Inputs (corpus is never committed):
          --corpus <path>       Document corpus (or EXTRACT_EVAL_CORPUS)
          --fixtures <path>     Smoke fixtures (defaults to <repo>/fixtures)
          --repo-root <path>    Repo root for fixture anchors (auto-detected)

        Extraction:
          --backend mock|mlx    Default: mock (CI-safe). MLX never falls back to mock.
          --model <id>          MLX model id
          --table-detection automatic|off

        Anchors:
          --anchors <file.json> Default: bundled seed anchors
          --no-anchors          Skip anchor evaluation (survey/accuracy)

        A/B:
          --config-a name:backend=mock,tableDetection=off
          --config-b name:backend=mock,tableDetection=automatic

        Output:
          --output <dir>        Default: eval-out
          --include-content     Include document/table cell text (private corpora!)

        Exit codes:
          0  success, all evaluated anchors passed
          1  one or more anchors failed
          2  usage / configuration error
        """
    }
}
