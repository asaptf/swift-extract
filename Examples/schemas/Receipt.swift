import Extract
import Foundation

/// Example schema used by the CLI, demo app, and README.
@Extractable
struct Receipt {
    let merchant: String
    let date: Date
    let total: Decimal
    @Guide("3-letter ISO currency code") let currency: String
    let items: [Item]

    @Extractable
    struct Item {
        let name: String
        let price: Decimal
        @Guide("null if not printed on the receipt") let quantity: Int?
    }
}
