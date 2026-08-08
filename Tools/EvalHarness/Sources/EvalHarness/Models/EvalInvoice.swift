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
