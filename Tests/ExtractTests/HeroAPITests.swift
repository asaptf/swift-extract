import Extract
import Foundation
import Testing

/// README hero sample — must compile and run against a mock session.
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

@Suite("Hero API")
struct HeroAPITests {
    @Test("README hero sample shape extracts a typed Invoice")
    func heroSample() async throws {
        let canned = """
            {
              "vendor": "Acme Supplies Co.",
              "dueDate": "2024-07-31",
              "total": 1250.00,
              "lineItems": [
                {"description": "Widget Pro", "amount": 500.00, "quantity": 2},
                {"description": "Support Plan", "amount": 250.00, "quantity": 1}
              ]
            }
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let document = """
            INVOICE
            Vendor: Acme Supplies Co.
            Due: July 31, 2024
            Widget Pro x2  $500.00 each
            Support Plan x1 $250.00
            Total: $1250.00
            """

        // Hero-shaped call: type inferred + convenience text overload.
        let invoice: Invoice = try await Extract.from(document, using: session)

        #expect(invoice.vendor == "Acme Supplies Co.")
        #expect(invoice.total == Decimal(string: "1250")!)
        #expect(invoice.lineItems.count == 2)
        #expect(invoice.lineItems[0].description == "Widget Pro")
        #expect(invoice.lineItems[0].quantity == 2)

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: invoice.dueDate)
        #expect(components.year == 2024)
        #expect(components.month == 7)
        #expect(components.day == 31)
    }

    @Test("Extract.detailed returns metadata")
    func detailed() async throws {
        let canned = """
            {"vendor":"X","dueDate":"2024-01-01","total":1,"lineItems":[]}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [canned]))
        let result: ExtractionResult<Invoice> = try await Extract.detailed(
            from: .text("Vendor X total 1 due 2024-01-01"),
            using: session
        )
        #expect(result.value.vendor == "X")
        #expect(result.attempts == 1)
        #expect(result.rawModelOutput.contains("vendor"))
    }
}
