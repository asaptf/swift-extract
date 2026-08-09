import Extract
import Foundation

public struct AccuracyFileRecord: Sendable {
    public var file: String
    public var relativePath: String
    public var hasGroundTruth: Bool
    public var paired: Bool
    public var unpairedReason: String?
    public var fieldScores: [FieldScore]
    public var extractionError: String?
    public var tableCount: Int
    public var hasLineItemShaped: Bool
    public var ingestionSeconds: Double
    public var extractionSeconds: Double
}

public struct AccuracySummary: Sendable {
    public var records: [AccuracyFileRecord]
    public var filesTotal: Int
    public var withGroundTruth: Int
    public var unpaired: Int
    public var scored: Int
    public var overallCorrect: Int
    public var overallTotal: Int
    public var presentCorrect: Int
    public var presentTotal: Int
    public var perField: [String: (correct: Int, total: Int)]
    public var perFieldPresent: [String: (correct: Int, total: Int)]
    public var sellerAccuracy: Double?
    public var filesWithLineItemShaped: Int
    public var lineItemShapedShare: Double

    public var overallAccuracy: Double {
        overallTotal == 0 ? 0 : Double(overallCorrect) / Double(overallTotal)
    }

    public var presentAccuracy: Double {
        presentTotal == 0 ? 0 : Double(presentCorrect) / Double(presentTotal)
    }

    public static func reduce(_ records: [AccuracyFileRecord]) -> AccuracySummary {
        let gt = records.filter(\.hasGroundTruth)
        let paired = gt.filter(\.paired)
        let unpaired = gt.filter { !$0.paired }.count
        var overallC = 0
        var overallT = 0
        var presentC = 0
        var presentT = 0
        var perField: [String: (Int, Int)] = [:]
        var perFieldPresent: [String: (Int, Int)] = [:]

        for rec in paired {
            for f in rec.fieldScores {
                overallT += 1
                if f.correct { overallC += 1 }
                var pf = perField[f.field, default: (0, 0)]
                pf.1 += 1
                if f.correct { pf.0 += 1 }
                perField[f.field] = pf
                if f.truthPresentInText {
                    presentT += 1
                    if f.correct { presentC += 1 }
                    var pp = perFieldPresent[f.field, default: (0, 0)]
                    pp.1 += 1
                    if f.correct { pp.0 += 1 }
                    perFieldPresent[f.field] = pp
                }
            }
        }

        let seller = perField["sellerName"]
        let sellerAcc = seller.map { $0.1 == 0 ? 0.0 : Double($0.0) / Double($0.1) }
        let ok = records.filter { $0.extractionError == nil }
        let shaped = ok.filter(\.hasLineItemShaped).count
        let n = max(ok.count, 1)

        return AccuracySummary(
            records: records,
            filesTotal: records.count,
            withGroundTruth: gt.count,
            unpaired: unpaired,
            scored: paired.count,
            overallCorrect: overallC,
            overallTotal: overallT,
            presentCorrect: presentC,
            presentTotal: presentT,
            perField: perField,
            perFieldPresent: perFieldPresent,
            sellerAccuracy: sellerAcc,
            filesWithLineItemShaped: shaped,
            lineItemShapedShare: Double(shaped) / Double(n)
        )
    }
}

public enum AccuracyRunner {
    public static func run(
        files: [URL],
        rootForRelative: URL,
        config: RunConfig,
        includeContent: Bool = false
    ) async throws -> AccuracySummary {
        // Install arithmetic gate for this arm; restore previous so A/B arms and
        // later runs do not leak state. validateInvariants has no options channel.
        let previousInvariant = EvalInvoice.InvariantProbe.isArithmeticEnabled
        EvalInvoice.InvariantProbe.setArithmeticEnabled(config.arithmeticInvariant)
        defer { EvalInvoice.InvariantProbe.setArithmeticEnabled(previousInvariant) }

        let session = try config.makeSession()
        var records: [AccuracyFileRecord] = []
        let started = Date()
        for (index, url) in files.enumerated() {
            let rec = await scoreOne(
                url: url,
                rootForRelative: rootForRelative,
                session: session,
                options: config.extractionOptions,
                includeContent: includeContent
            )
            records.append(rec)
            // Progress to stderr only — model runs take minutes per file and a silent
            // run is indistinguishable from a hung one. Reports stay metrics-only.
            let elapsed = Int(Date().timeIntervalSince(started))
            let line =
                "[\(config.name) \(index + 1)/\(files.count)] \(rec.relativePath) (\(elapsed)s)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        records.sort { $0.relativePath < $1.relativePath }
        return AccuracySummary.reduce(records)
    }

    private static func scoreOne(
        url: URL,
        rootForRelative: URL,
        session: ExtractionSession,
        options: ExtractionOptions,
        includeContent: Bool
    ) async -> AccuracyFileRecord {
        _ = includeContent  // predictions never dump private content unless future flag uses it
        let relative = SurveyRunner.relativePath(url, root: rootForRelative)
        let ingestStart = ContinuousClock.now
        let inspection: DocumentInspection
        do {
            inspection = try await Extract.inspect(url, tableDetection: options.tableDetection)
        } catch {
            let elapsed = seconds(since: ingestStart)
            return AccuracyFileRecord(
                file: url.path,
                relativePath: relative,
                hasGroundTruth: false,
                paired: false,
                unpairedReason: nil,
                fieldScores: [],
                extractionError: "inspect: \(error)",
                tableCount: 0,
                hasLineItemShaped: false,
                ingestionSeconds: elapsed,
                extractionSeconds: 0
            )
        }
        let ingestSec = seconds(since: ingestStart)

        var truth: InvoiceGroundTruth?
        if url.pathExtension.lowercased() == "pdf" {
            truth = try? FacturXExtractor.groundTruth(fromPDF: url)
        }

        guard let truth else {
            return AccuracyFileRecord(
                file: url.path,
                relativePath: relative,
                hasGroundTruth: false,
                paired: false,
                unpairedReason: nil,
                fieldScores: [],
                extractionError: nil,
                tableCount: inspection.tables.count,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(inspection.tables),
                ingestionSeconds: ingestSec,
                extractionSeconds: 0
            )
        }

        // Pairing guard — never score against a truth that may belong to another document.
        guard FieldScoring.isPaired(truth: truth, documentText: inspection.fullText) else {
            return AccuracyFileRecord(
                file: url.path,
                relativePath: relative,
                hasGroundTruth: true,
                paired: false,
                unpairedReason:
                    "pairing token '\(truth.pairingToken ?? "?")' not found in extracted text",
                fieldScores: [],
                extractionError: nil,
                tableCount: inspection.tables.count,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(inspection.tables),
                ingestionSeconds: ingestSec,
                extractionSeconds: 0
            )
        }

        let extractStart = ContinuousClock.now
        do {
            let result = try await Extract.detailed(
                from: .fileURL(url),
                as: EvalInvoice.self,
                using: session,
                options: options
            )
            let extractSec = seconds(since: extractStart)
            let card = FieldScoring.score(
                file: relative,
                truth: truth,
                predicted: result.value,
                documentText: inspection.fullText
            )
            return AccuracyFileRecord(
                file: url.path,
                relativePath: relative,
                hasGroundTruth: true,
                paired: true,
                unpairedReason: nil,
                fieldScores: card.fields,
                extractionError: nil,
                tableCount: result.tables.count,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(result.tables),
                ingestionSeconds: ingestSec,
                extractionSeconds: extractSec
            )
        } catch {
            let extractSec = seconds(since: extractStart)
            return AccuracyFileRecord(
                file: url.path,
                relativePath: relative,
                hasGroundTruth: true,
                paired: true,
                unpairedReason: nil,
                fieldScores: [],
                extractionError: String(describing: error),
                tableCount: inspection.tables.count,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(inspection.tables),
                ingestionSeconds: ingestSec,
                extractionSeconds: extractSec
            )
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}
