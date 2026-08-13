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
    /// Paired file whose extraction threw — scores are synthetic all-miss fields from GT.
    public var hardFailure: Bool
    public var tableCount: Int
    public var hasLineItemShaped: Bool
    /// ``CollectionSource/reportToken`` (`model` / `geometry` / `geometryFallback`).
    public var collectionSource: String
    /// Set when ``collectionSource`` is `geometryFallback`.
    public var collectionFallbackReason: String?
    public var ingestionSeconds: Double
    public var extractionSeconds: Double
}

public struct AccuracySummary: Sendable {
    public var records: [AccuracyFileRecord]
    public var filesTotal: Int
    public var withGroundTruth: Int
    public var unpaired: Int
    /// Paired files that extracted successfully and contributed to ``overallAccuracy``.
    public var scored: Int
    /// Paired files whose extraction threw (hard failures).
    public var hardFailures: Int
    /// `hardFailures / (scored + hardFailures)`; 0 when no paired files.
    public var hardFailureShare: Double
    public var overallCorrect: Int
    public var overallTotal: Int
    public var presentCorrect: Int
    public var presentTotal: Int
    /// Failure-inclusive: successful scores plus every GT field on hard failures counted incorrect.
    public var failureInclusiveCorrect: Int
    public var failureInclusiveTotal: Int
    public var failureInclusivePresentCorrect: Int
    public var failureInclusivePresentTotal: Int
    public var perField: [String: (correct: Int, total: Int)]
    public var perFieldPresent: [String: (correct: Int, total: Int)]
    public var sellerAccuracy: Double?
    public var filesWithLineItemShaped: Int
    public var lineItemShapedShare: Double
    /// Scored files whose collection came from table geometry.
    public var geometryUsed: Int
    /// Scored files that requested geometry but fell back to the model path.
    public var geometryFallback: Int
    /// Scored files whose collection came from the model (including default path).
    public var collectionFromModel: Int

    /// Field accuracy over successful extractions only (historical definition; hard failures excluded).
    public var overallAccuracy: Double {
        overallTotal == 0 ? 0 : Double(overallCorrect) / Double(overallTotal)
    }

    /// Present-in-text accuracy over successful extractions only (historical definition).
    public var presentAccuracy: Double {
        presentTotal == 0 ? 0 : Double(presentCorrect) / Double(presentTotal)
    }

    /// Field accuracy counting hard-failed files as all-miss on every GT-bearing field.
    public var failureInclusiveAccuracy: Double {
        failureInclusiveTotal == 0
            ? 0 : Double(failureInclusiveCorrect) / Double(failureInclusiveTotal)
    }

    /// Present-in-text variant of ``failureInclusiveAccuracy``.
    public var failureInclusivePresentAccuracy: Double {
        failureInclusivePresentTotal == 0
            ? 0
            : Double(failureInclusivePresentCorrect) / Double(failureInclusivePresentTotal)
    }

    public static func reduce(_ records: [AccuracyFileRecord]) -> AccuracySummary {
        let gt = records.filter(\.hasGroundTruth)
        let paired = gt.filter(\.paired)
        let unpaired = gt.filter { !$0.paired }.count
        let hardFailed = paired.filter(\.hardFailure)
        let successful = paired.filter { !$0.hardFailure }
        var overallC = 0
        var overallT = 0
        var presentC = 0
        var presentT = 0
        var fiC = 0
        var fiT = 0
        var fiPresentC = 0
        var fiPresentT = 0
        var perField: [String: (Int, Int)] = [:]
        var perFieldPresent: [String: (Int, Int)] = [:]

        // Historical metrics: only successful extractions contribute field scores.
        for rec in successful {
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

        // Failure-inclusive: successful scores + hard failures as all-miss on GT fields.
        for rec in successful {
            for f in rec.fieldScores {
                fiT += 1
                if f.correct { fiC += 1 }
                if f.truthPresentInText {
                    fiPresentT += 1
                    if f.correct { fiPresentC += 1 }
                }
            }
        }
        for rec in hardFailed {
            for f in rec.fieldScores {
                fiT += 1
                // correct is always false for synthetic hard-failure scores
                if f.truthPresentInText {
                    fiPresentT += 1
                }
            }
        }

        let seller = perField["sellerName"]
        let sellerAcc = seller.map { $0.1 == 0 ? 0.0 : Double($0.0) / Double($0.1) }
        let ok = records.filter { $0.extractionError == nil }
        let shaped = ok.filter(\.hasLineItemShaped).count
        let n = max(ok.count, 1)
        let pairedCount = successful.count + hardFailed.count
        let hardShare =
            pairedCount == 0 ? 0.0 : Double(hardFailed.count) / Double(pairedCount)
        let geometryUsed = successful.filter { $0.collectionSource == "geometry" }.count
        let geometryFallback = successful.filter { $0.collectionSource == "geometryFallback" }
            .count
        let collectionFromModel = successful.filter { $0.collectionSource == "model" }.count

        return AccuracySummary(
            records: records,
            filesTotal: records.count,
            withGroundTruth: gt.count,
            unpaired: unpaired,
            scored: successful.count,
            hardFailures: hardFailed.count,
            hardFailureShare: hardShare,
            overallCorrect: overallC,
            overallTotal: overallT,
            presentCorrect: presentC,
            presentTotal: presentT,
            failureInclusiveCorrect: fiC,
            failureInclusiveTotal: fiT,
            failureInclusivePresentCorrect: fiPresentC,
            failureInclusivePresentTotal: fiPresentT,
            perField: perField,
            perFieldPresent: perFieldPresent,
            sellerAccuracy: sellerAcc,
            filesWithLineItemShaped: shaped,
            lineItemShapedShare: Double(shaped) / Double(n),
            geometryUsed: geometryUsed,
            geometryFallback: geometryFallback,
            collectionFromModel: collectionFromModel
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
        EvalInvoice.InvariantProbe.setArithmeticEnabled(config.arithmeticInvariant.isEnabled)
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
                hardFailure: false,
                tableCount: 0,
                hasLineItemShaped: false,
                collectionSource: "model",
                collectionFallbackReason: nil,
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
                hardFailure: false,
                tableCount: inspection.tables.count,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(inspection.tables),
                collectionSource: "model",
                collectionFallbackReason: nil,
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
                hardFailure: false,
                tableCount: inspection.tables.count,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(inspection.tables),
                collectionSource: "model",
                collectionFallbackReason: nil,
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
                hardFailure: false,
                tableCount: result.tables.count,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(result.tables),
                collectionSource: result.collectionSource.reportToken,
                collectionFallbackReason: result.collectionSource.fallbackReason,
                ingestionSeconds: ingestSec,
                extractionSeconds: extractSec
            )
        } catch {
            let extractSec = seconds(since: extractStart)
            // Synthetic all-miss scores so failure-inclusive metrics have a denominator
            // and the report cannot hide a total wipeout as 0/0.
            let card = FieldScoring.score(
                file: relative,
                truth: truth,
                predicted: EvalInvoice(),
                documentText: inspection.fullText
            )
            return AccuracyFileRecord(
                file: url.path,
                relativePath: relative,
                hasGroundTruth: true,
                paired: true,
                unpairedReason: nil,
                fieldScores: card.fields,
                extractionError: String(describing: error),
                hardFailure: true,
                tableCount: inspection.tables.count,
                hasLineItemShaped: TableMetrics.hasLineItemShapedTable(inspection.tables),
                collectionSource: "model",
                collectionFallbackReason: nil,
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
