import Foundation
import Testing

@testable import EvalHarness

@Suite("AccuracySummary.reduce")
struct AccuracySummaryTests {

    private func score(
        field: String,
        correct: Bool,
        present: Bool = true
    ) -> FieldScore {
        FieldScore(
            field: field,
            correct: correct,
            truthPresentInText: present,
            truthValue: "t",
            predictedValue: correct ? "t" : nil
        )
    }

    private func record(
        path: String,
        hasGT: Bool = true,
        paired: Bool = true,
        hardFailure: Bool = false,
        fields: [FieldScore] = [],
        extractionError: String? = nil
    ) -> AccuracyFileRecord {
        AccuracyFileRecord(
            file: "/tmp/\(path)",
            relativePath: path,
            hasGroundTruth: hasGT,
            paired: paired,
            unpairedReason: paired ? nil : "unpaired",
            fieldScores: fields,
            extractionError: extractionError,
            hardFailure: hardFailure,
            tableCount: 0,
            hasLineItemShaped: false,
            ingestionSeconds: 0,
            extractionSeconds: 0
        )
    }

    @Test("no failures: overall matches historical definition and equals failure-inclusive")
    func noFailuresUnchanged() {
        let records = [
            record(
                path: "a.pdf",
                fields: [
                    score(field: "invoiceNumber", correct: true),
                    score(field: "grandTotal", correct: false),
                ]
            ),
            record(
                path: "b.pdf",
                fields: [
                    score(field: "invoiceNumber", correct: true),
                    score(field: "grandTotal", correct: true),
                ]
            ),
        ]
        let s = AccuracySummary.reduce(records)
        #expect(s.scored == 2)
        #expect(s.hardFailures == 0)
        #expect(s.hardFailureShare == 0)
        #expect(s.overallCorrect == 3)
        #expect(s.overallTotal == 4)
        #expect(s.overallAccuracy == 0.75)
        #expect(s.failureInclusiveCorrect == 3)
        #expect(s.failureInclusiveTotal == 4)
        #expect(s.failureInclusiveAccuracy == s.overallAccuracy)
        #expect(s.presentCorrect == 3)
        #expect(s.presentTotal == 4)
        #expect(s.failureInclusivePresentCorrect == 3)
        #expect(s.failureInclusivePresentTotal == 4)
    }

    @Test("mix of scored and hard-failed records yields expected counts for both metrics")
    func mixScoredAndHardFailed() {
        // Successful: 2/2 correct.
        let ok = record(
            path: "ok.pdf",
            fields: [
                score(field: "invoiceNumber", correct: true),
                score(field: "grandTotal", correct: true, present: false),
            ]
        )
        // Hard failure: 3 GT fields, all miss (synthetic).
        let fail = record(
            path: "fail.pdf",
            hardFailure: true,
            fields: [
                score(field: "invoiceNumber", correct: false),
                score(field: "sellerName", correct: false),
                score(field: "grandTotal", correct: false, present: false),
            ],
            extractionError: "validationFailed"
        )
        // Unpaired: ignored by both metrics.
        let unpaired = record(
            path: "unpaired.pdf",
            paired: false,
            fields: [],
            extractionError: nil
        )
        // No GT: ignored.
        let noGT = record(path: "image.png", hasGT: false, paired: false)

        let s = AccuracySummary.reduce([ok, fail, unpaired, noGT])

        #expect(s.withGroundTruth == 3)
        #expect(s.unpaired == 1)
        #expect(s.scored == 1)
        #expect(s.hardFailures == 1)
        #expect(s.hardFailureShare == 0.5)

        // Historical: only the successful file (2 fields).
        #expect(s.overallCorrect == 2)
        #expect(s.overallTotal == 2)
        #expect(s.overallAccuracy == 1.0)
        #expect(s.presentCorrect == 1)
        #expect(s.presentTotal == 1)

        // Failure-inclusive: 2 correct + 3 incorrect = 2/5.
        #expect(s.failureInclusiveCorrect == 2)
        #expect(s.failureInclusiveTotal == 5)
        #expect(abs(s.failureInclusiveAccuracy - 0.4) < 1e-9)
        // Present: successful 1/1 + hard-fail present fields 0/2 = 1/3.
        #expect(s.failureInclusivePresentCorrect == 1)
        #expect(s.failureInclusivePresentTotal == 3)
    }

    @Test("every file hard-fails: historical is 0/0; failure-inclusive is 0/n and count is visible")
    func allHardFail() throws {
        let fields = [
            score(field: "invoiceNumber", correct: false),
            score(field: "grandTotal", correct: false),
            score(field: "sellerName", correct: false),
        ]
        let records = (1...3).map { i in
            record(
                path: "f\(i).pdf",
                hardFailure: true,
                fields: fields,
                extractionError: "validationFailed: arithmetic"
            )
        }
        let s = AccuracySummary.reduce(records)

        #expect(s.scored == 0)
        #expect(s.hardFailures == 3)
        #expect(s.hardFailureShare == 1.0)
        #expect(s.overallCorrect == 0)
        #expect(s.overallTotal == 0)
        #expect(s.overallAccuracy == 0)
        #expect(s.failureInclusiveCorrect == 0)
        #expect(s.failureInclusiveTotal == 9)
        #expect(s.failureInclusiveAccuracy == 0)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-hard-fail-\(UUID().uuidString)", isDirectory: true)
        try ReportWriter.writeAccuracy(
            s,
            outputDir: dir,
            configLabel: "name=demo backend=mock invariant=true note=forced-arithmetic-violation"
        )
        let md = try String(
            contentsOf: dir.appendingPathComponent("accuracy.md"),
            encoding: .utf8
        )
        #expect(md.contains("Hard failures"))
        #expect(md.contains("**3**"))
        #expect(md.contains("100.0% of paired"))
        #expect(md.contains("Failure-inclusive field accuracy"))
        #expect(md.contains("0.0% (0/9)"))
        #expect(md.contains("successful extractions only"))
        #expect(md.contains("f1.pdf"))
        #expect(md.contains("validationFailed"))
        // Headline case: not only 0/0 without context.
        #expect(md.contains("(0/0)"))  // historical row still shows 0/0
        #expect(md.contains("Hard failures** (paired, extraction threw) | **3**"))

        let jsonl = try String(
            contentsOf: dir.appendingPathComponent("accuracy.jsonl"),
            encoding: .utf8
        )
        #expect(jsonl.contains("\"hardFailure\":true"))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("AB field delta treats nil as incorrect")
    func abFieldDeltaNilAsMiss() {
        #expect(ABCompareRunner.fieldDelta(aCorrect: true, bCorrect: nil) == -1)
        #expect(ABCompareRunner.fieldDelta(aCorrect: nil, bCorrect: true) == 1)
        #expect(ABCompareRunner.fieldDelta(aCorrect: false, bCorrect: nil) == 0)
        #expect(ABCompareRunner.fieldDelta(aCorrect: true, bCorrect: false) == -1)
        #expect(ABCompareRunner.fieldDelta(aCorrect: true, bCorrect: true) == 0)
    }
}

@Suite("Arithmetic invariant mode")
struct ArithmeticInvariantModeTests {
    @Test("parse accepts historical booleans and the report token")
    func parseModes() throws {
        #expect(try ArithmeticInvariantMode.parse("true") == .on)
        #expect(try ArithmeticInvariantMode.parse("TRUE") == .on)
        #expect(try ArithmeticInvariantMode.parse("on") == .on)
        #expect(try ArithmeticInvariantMode.parse("strict") == .on)
        #expect(try ArithmeticInvariantMode.parse("false") == .off)
        #expect(try ArithmeticInvariantMode.parse("off") == .off)
        #expect(try ArithmeticInvariantMode.parse("0") == .off)
        #expect(try ArithmeticInvariantMode.parse("report") == .report)
        #expect(try ArithmeticInvariantMode.parse("reportViolations") == .report)
        #expect(throws: CLIParseError.self) {
            _ = try ArithmeticInvariantMode.parse("maybe")
        }
    }

    @Test("report labels keep true/false and print report")
    func reportLabels() {
        let on = RunConfig(name: "a", arithmeticInvariant: .on)
        let off = RunConfig(name: "b", arithmeticInvariant: .off)
        let report = RunConfig(name: "c", arithmeticInvariant: .report)
        #expect(on.reportLabel.contains("invariant=true"))
        #expect(!on.reportLabel.contains("note=arithmetic-invariant-off"))
        #expect(off.reportLabel.contains("invariant=false"))
        #expect(off.reportLabel.contains("note=arithmetic-invariant-off"))
        #expect(report.reportLabel.contains("invariant=report"))
        #expect(on.extractionOptions.invariantPolicy == .strict)
        #expect(off.extractionOptions.invariantPolicy == .strict)
        #expect(report.extractionOptions.invariantPolicy == .reportViolations)
        #expect(on.arithmeticInvariant.isEnabled)
        #expect(!off.arithmeticInvariant.isEnabled)
        #expect(report.arithmeticInvariant.isEnabled)
    }
}
