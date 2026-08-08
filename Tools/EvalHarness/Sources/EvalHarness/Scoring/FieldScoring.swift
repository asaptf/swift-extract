import Foundation

public struct FieldScore: Sendable, Equatable {
    public var field: String
    public var correct: Bool
    public var truthPresentInText: Bool
    public var truthValue: String?
    public var predictedValue: String?

    public init(
        field: String,
        correct: Bool,
        truthPresentInText: Bool,
        truthValue: String? = nil,
        predictedValue: String? = nil
    ) {
        self.field = field
        self.correct = correct
        self.truthPresentInText = truthPresentInText
        self.truthValue = truthValue
        self.predictedValue = predictedValue
    }
}

public struct AccuracyScorecard: Sendable {
    public var file: String
    public var paired: Bool
    public var unpairedReason: String?
    public var fields: [FieldScore]
    public var extractionError: String?

    public init(
        file: String,
        paired: Bool,
        unpairedReason: String? = nil,
        fields: [FieldScore] = [],
        extractionError: String? = nil
    ) {
        self.file = file
        self.paired = paired
        self.unpairedReason = unpairedReason
        self.fields = fields
        self.extractionError = extractionError
    }

    public var overallCorrect: Int { fields.filter(\.correct).count }
    public var overallTotal: Int { fields.count }
    public var presentCorrect: Int {
        fields.filter { $0.truthPresentInText && $0.correct }.count
    }
    public var presentTotal: Int {
        fields.filter(\.truthPresentInText).count
    }
}

public enum FieldScoring {
    /// Score predicted invoice fields against ground truth.
    ///
    /// Only fields with a non-nil truth value are scored. `truthPresentInText`
    /// gates the restricted accuracy profile (ZUGFeRD MINIMUM values that never
    /// appear on the page are still counted in overall accuracy).
    public static func score(
        file: String,
        truth: InvoiceGroundTruth,
        predicted: EvalInvoice,
        documentText: String
    ) -> AccuracyScorecard {
        var fields: [FieldScore] = []

        if let t = truth.invoiceNumber {
            let p = predicted.invoiceNumber
            fields.append(
                FieldScore(
                    field: "invoiceNumber",
                    correct: p.map { FieldNormalization.textsEqual($0, t) } ?? false,
                    truthPresentInText: FieldNormalization.textContains(documentText, needle: t),
                    truthValue: t,
                    predictedValue: p
                )
            )
        }
        if let t = truth.issueDate {
            let p = predicted.issueDate
            fields.append(
                FieldScore(
                    field: "issueDate",
                    correct: p.map { FieldNormalization.calendarDaysEqual($0, t) } ?? false,
                    truthPresentInText: dateAppearsInText(t, documentText),
                    truthValue: FieldNormalization.formatDate(t),
                    predictedValue: p.map(FieldNormalization.formatDate)
                )
            )
        }
        if let t = truth.currency {
            let p = predicted.currency
            fields.append(
                FieldScore(
                    field: "currency",
                    correct: p.map { FieldNormalization.textsEqual($0, t) } ?? false,
                    truthPresentInText: FieldNormalization.textContains(documentText, needle: t),
                    truthValue: t,
                    predictedValue: p
                )
            )
        }
        if let t = truth.sellerName {
            let p = predicted.sellerName
            fields.append(
                FieldScore(
                    field: "sellerName",
                    correct: p.map { sellerMatch($0, truth: t) } ?? false,
                    truthPresentInText: FieldNormalization.textContains(documentText, needle: t),
                    truthValue: t,
                    predictedValue: p
                )
            )
        }
        if let t = truth.grandTotal {
            let p = predicted.grandTotal
            fields.append(
                FieldScore(
                    field: "grandTotal",
                    correct: p.map { FieldNormalization.decimalsEqual($0, t) } ?? false,
                    truthPresentInText: amountAppearsInText(t, documentText),
                    truthValue: FieldNormalization.formatDecimal(t),
                    predictedValue: p.map(FieldNormalization.formatDecimal)
                )
            )
        }
        if let t = truth.taxTotal {
            let p = predicted.taxTotal
            fields.append(
                FieldScore(
                    field: "taxTotal",
                    correct: p.map { FieldNormalization.decimalsEqual($0, t) } ?? false,
                    truthPresentInText: amountAppearsInText(t, documentText),
                    truthValue: FieldNormalization.formatDecimal(t),
                    predictedValue: p.map(FieldNormalization.formatDecimal)
                )
            )
        }

        // Line-item descriptions (ordered match by description string).
        for (idx, line) in truth.lineItems.enumerated() {
            guard let tDesc = line.description, !tDesc.isEmpty else { continue }
            let predictedLines = predicted.lineItems ?? []
            let match = predictedLines.first {
                ($0.description).map { FieldNormalization.textsEqual($0, tDesc) } ?? false
                    || ($0.description).map {
                        FieldNormalization.textContains($0, needle: tDesc)
                            || FieldNormalization.textContains(tDesc, needle: $0)
                    } ?? false
            }
            fields.append(
                FieldScore(
                    field: "lineItems[\(idx)].description",
                    correct: match != nil,
                    truthPresentInText: FieldNormalization.textContains(documentText, needle: tDesc),
                    truthValue: tDesc,
                    predictedValue: match?.description
                )
            )
            if let tAmt = line.lineTotal {
                let amtOK =
                    match?.lineTotal.map { FieldNormalization.decimalsEqual($0, tAmt) } ?? false
                fields.append(
                    FieldScore(
                        field: "lineItems[\(idx)].lineTotal",
                        correct: amtOK,
                        truthPresentInText: amountAppearsInText(tAmt, documentText),
                        truthValue: FieldNormalization.formatDecimal(tAmt),
                        predictedValue: match?.lineTotal.map(FieldNormalization.formatDecimal)
                    )
                )
            }
        }

        return AccuracyScorecard(file: file, paired: true, fields: fields)
    }

    /// Pairing guard: a distinctive ground-truth value must appear in extracted text.
    public static func isPaired(truth: InvoiceGroundTruth, documentText: String) -> Bool {
        guard let token = truth.pairingToken else {
            // No distinctive token — require seller or grand total in text.
            if let s = truth.sellerName, FieldNormalization.textContains(documentText, needle: s) {
                return true
            }
            if let g = truth.grandTotal, amountAppearsInText(g, documentText) {
                return true
            }
            return false
        }
        return FieldNormalization.textContains(documentText, needle: token)
    }

    private static func sellerMatch(_ predicted: String, truth: String) -> Bool {
        if FieldNormalization.textsEqual(predicted, truth) { return true }
        // Allow substring either way (OCR may drop legal form suffixes).
        return FieldNormalization.textContains(predicted, needle: truth)
            || FieldNormalization.textContains(truth, needle: predicted)
    }

    private static func dateAppearsInText(_ date: Date, _ text: String) -> Bool {
        let iso = FieldNormalization.formatDate(date)
        if FieldNormalization.textContains(text, needle: iso) { return true }
        // CII format 102 yyyyMMdd
        let compact = iso.replacingOccurrences(of: "-", with: "")
        if FieldNormalization.textContains(text, needle: compact) { return true }
        // Common EU print form dd.MM.yyyy
        let parts = iso.split(separator: "-")
        if parts.count == 3 {
            let dotted = "\(parts[2]).\(parts[1]).\(parts[0])"
            if FieldNormalization.textContains(text, needle: dotted) { return true }
        }
        return false
    }

    private static func amountAppearsInText(_ amount: Decimal, _ text: String) -> Bool {
        let raw = FieldNormalization.formatDecimal(amount)
        if FieldNormalization.textContains(text, needle: raw) { return true }
        // European decimal comma
        let comma = raw.replacingOccurrences(of: ".", with: ",")
        if FieldNormalization.textContains(text, needle: comma) { return true }
        // Without trailing zeros noise: try 2-dp forms
        let ns = NSDecimalNumber(decimal: amount)
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        if let s = f.string(from: ns), FieldNormalization.textContains(text, needle: s) {
            return true
        }
        f.locale = Locale(identifier: "de_DE")
        if let s = f.string(from: ns), FieldNormalization.textContains(text, needle: s) {
            return true
        }
        return false
    }
}
