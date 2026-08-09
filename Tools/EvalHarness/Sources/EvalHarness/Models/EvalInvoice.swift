import Extract
import Foundation

/// Schema used by the harness for Factur-X / ZUGFeRD accuracy scoring.
///
/// Field names mirror EN16931-ish invoice headers rather than the demo `Invoice`
/// type, so ground-truth mapping stays obvious.
@Extractable
public struct EvalInvoice {
    @Guide("Invoice number / ID as printed")
    public var invoiceNumber: String?

    @Guide("Issue date of the invoice (ISO 8601 when possible)")
    public var issueDate: Date?

    @Guide("3-letter ISO currency code")
    public var currency: String?

    @Guide("Seller / vendor / supplier name")
    public var sellerName: String?

    @Guide("Grand total / amount due including tax")
    public var grandTotal: Decimal?

    @Guide("Total tax / VAT amount")
    public var taxTotal: Decimal?

    public var lineItems: [EvalLineItem]?

    public init(
        invoiceNumber: String? = nil,
        issueDate: Date? = nil,
        currency: String? = nil,
        sellerName: String? = nil,
        grandTotal: Decimal? = nil,
        taxTotal: Decimal? = nil,
        lineItems: [EvalLineItem]? = nil
    ) {
        self.invoiceNumber = invoiceNumber
        self.issueDate = issueDate
        self.currency = currency
        self.sellerName = sellerName
        self.grandTotal = grandTotal
        self.taxTotal = taxTotal
        self.lineItems = lineItems
    }

    /// Arithmetic check: sum(lineTotals) + tax ≈ grandTotal within money tolerance.
    ///
    /// Skips (does not fail) when the pieces needed are missing — empty/absent line
    /// items, a nil grand total, or any line item without a `lineTotal`. Missing
    /// `taxTotal` is treated as zero (tax-exempt / zero-VAT invoices). Not
    /// corpus-specific; same spirit as the documented Receipt example.
    ///
    /// When ``InvariantProbe/isArithmeticEnabled`` is `false` (run-level switch),
    /// this is a no-op so low-capacity models can still produce scored fields
    /// instead of dying entirely in `validationFailed`.
    public func validateInvariants() throws {
        guard InvariantProbe.isArithmeticEnabled else { return }

        guard let items = lineItems, !items.isEmpty else {
            InvariantProbe.recordSkip()
            return
        }
        guard let total = grandTotal else {
            InvariantProbe.recordSkip()
            return
        }

        var itemsSum = Decimal.zero
        for item in items {
            guard let lineTotal = item.lineTotal else {
                InvariantProbe.recordSkip()
                return
            }
            itemsSum += lineTotal
        }

        let tax = taxTotal ?? Decimal.zero
        let expected = itemsSum + tax
        if !Extract.isApproximatelyEqual(
            total,
            to: expected,
            tolerance: Extract.defaultMoneyTolerance
        ) {
            InvariantProbe.recordCheck(violated: true)
            throw InvariantValidationError(
                path: "grandTotal",
                expected:
                    "line items sum + tax ≈ \(expected) (tolerance \(Extract.defaultMoneyTolerance))",
                found: "\(total)"
            )
        }
        InvariantProbe.recordCheck(violated: false)
    }

    /// Process-local counters so the harness can measure how often the invariant
    /// fires and whether repair recovers. Reset per arm extraction.
    ///
    /// Also owns the run-level arithmetic gate: ``Extractable/validateInvariants()``
    /// has no options channel, so the harness installs enable/disable here before
    /// an arm's extractions (see ``RunConfig/arithmeticInvariant``).
    public enum InvariantProbe: Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var checks = 0
        nonisolated(unsafe) private static var violations = 0
        nonisolated(unsafe) private static var skips = 0
        /// Default `true` — matches historical harness behaviour.
        nonisolated(unsafe) private static var arithmeticEnabled = true

        public static func reset() {
            lock.lock()
            checks = 0
            violations = 0
            skips = 0
            lock.unlock()
        }

        /// Enable or disable the arithmetic check for subsequent extractions.
        public static func setArithmeticEnabled(_ enabled: Bool) {
            lock.lock()
            arithmeticEnabled = enabled
            lock.unlock()
        }

        public static var isArithmeticEnabled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return arithmeticEnabled
        }

        public static func recordSkip() {
            lock.lock()
            skips += 1
            lock.unlock()
        }

        public static func recordCheck(violated: Bool) {
            lock.lock()
            checks += 1
            if violated { violations += 1 }
            lock.unlock()
        }

        public static func snapshot() -> (checks: Int, violations: Int, skips: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (checks, violations, skips)
        }
    }

    @Extractable
    public struct EvalLineItem {
        public var description: String?
        public var quantity: Decimal?
        public var lineTotal: Decimal?

        public init(
            description: String? = nil,
            quantity: Decimal? = nil,
            lineTotal: Decimal? = nil
        ) {
            self.description = description
            self.quantity = quantity
            self.lineTotal = lineTotal
        }
    }
}
