import Foundation

/// Parsed EN16931 / CII invoice ground truth from an embedded Factur-X / ZUGFeRD XML.
public struct InvoiceGroundTruth: Sendable, Equatable {
    public var invoiceNumber: String?
    public var issueDate: Date?
    public var currency: String?
    public var sellerName: String?
    public var grandTotal: Decimal?
    public var taxTotal: Decimal?
    public var lineItems: [LineItem]

    public struct LineItem: Sendable, Equatable {
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

    public init(
        invoiceNumber: String? = nil,
        issueDate: Date? = nil,
        currency: String? = nil,
        sellerName: String? = nil,
        grandTotal: Decimal? = nil,
        taxTotal: Decimal? = nil,
        lineItems: [LineItem] = []
    ) {
        self.invoiceNumber = invoiceNumber
        self.issueDate = issueDate
        self.currency = currency
        self.sellerName = sellerName
        self.grandTotal = grandTotal
        self.taxTotal = taxTotal
        self.lineItems = lineItems
    }

    /// Distinctive value used for the pairing guard (prefer invoice number).
    public var pairingToken: String? {
        if let n = invoiceNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            return n
        }
        if let s = sellerName?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        return nil
    }
}
