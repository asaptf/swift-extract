import Extract
import Foundation

/// Example schema used by the CLI and README.
/// Keep in sync with the embedded `Invoice` type in `Sources/ExtractCLI`.
@Extractable
struct Invoice {
    let vendor: String
    @Guide("ISO 8601 format") let dueDate: Date
    let total: Decimal
    let lineItems: [LineItem]

    @Extractable
    struct LineItem {
        let description: String
        let amount: Decimal
        let quantity: Int
    }
}
