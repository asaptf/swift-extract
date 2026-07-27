# Examples cookbook

Copy-paste oriented recipes. All snippets assume `import Extract` and a configured `session: ExtractionSession`.

---

## 1. Receipt from a photo

```swift
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
        let quantity: Int?
    }
}

let photo = Bundle.main.url(forResource: "receipt", withExtension: "png")!
let receipt: Receipt = try await Extract.from(photo, using: session)

for item in receipt.items {
    print("- \(item.name): \(item.price)")
}
```

For offline / on-device backends (small MLX models from Hugging Face, model size
vs. field complexity), see [Backends → Choosing a small local model](Backends.md#choosing-a-small-local-model).

---

## 2. Invoice PDF with nested lines

```swift
@Extractable
struct Invoice {
    let vendor: String
    @Guide("ISO 8601 date") let dueDate: Date
    let total: Decimal
    let lineItems: [LineItem]

    @Extractable
    struct LineItem {
        let description: String
        let amount: Decimal
        let quantity: Int
    }
}

let pdf = URL(fileURLWithPath: "fixtures/invoice.pdf")
let invoice: Invoice = try await Extract.from(.pdf(pdf), using: session)
print(invoice.vendor, invoice.total)
```

Nested line items usually need a stronger model than a bare total. Prefer
~3B local or a cloud mini model; see
[Choosing a small local model](Backends.md#choosing-a-small-local-model).

---

## 3. Email / confirmation text

```swift
@Extractable
struct ShippingConfirmation {
    let orderId: String
    let carrier: String
    let trackingNumber: String?
    let eta: Date?
    let shipTo: String
}

let body = """
Order #88421 confirmed.
Carrier: UPS
Tracking: 1Z999AA10123456784
ETA: May 12, 2024
Ship to: 1 Infinite Loop, Cupertino CA
"""

let conf: ShippingConfirmation = try await Extract.from(body, using: session)
```

---

## 4. String-backed enums

```swift
enum Priority: String, Codable, Sendable, CaseIterable {
    case low, medium, high
}
extension Priority: Extractable {}

@Extractable
struct Ticket {
    let title: String
    let priority: Priority
    let assignee: String?
}

let ticket: Ticket = try await Extract.from(
    "Urgent: login broken for enterprise tenants — assign to SRE",
    using: session
)
// ticket.priority == .high  (model + schema enum guide)
```

---

## 5. Repair retries (Instructor-style)

```swift
var options = ExtractionOptions()
options.maxRetries = 3   // up to 4 total attempts

do {
    let value: Invoice = try await Extract.from(source, using: session, options: options)
} catch let ExtractionError.validationFailed(attempts, last, raw) {
    print("Gave up after \(attempts) attempts")
    print(last)
    print(raw)
}
```

On each failure the next prompt includes machine-readable field errors, e.g.  
`field total: expected number, got string 'twelve'`.

---

## 6. Large documents (chunk + merge)

```swift
var options = ExtractionOptions()
options.chunkingStrategy = .automatic
options.softContextCharacterBudget = 8_000

// Or force small chunks while testing:
options.chunkingStrategy = .fixed(characterBudget: 2_000)

let result = try await Extract.detailed(
    from: .text(hugeTranscript),
    using: session,
    options: options
)
print("chunks:", result.chunksUsed, "attempts:", result.attempts)
```

---

## 7. Locale-aware dates

```swift
var options = ExtractionOptions()
options.locale = Locale(identifier: "en_GB")

// "05/06/2024" tends to be read as 5 June under en_GB
let event: CalendarEvent = try await Extract.from(ukEmail, using: session, options: options)
```

---

## 8. Unit tests without network

```swift
import Testing
import Extract

@Test
func extractsMerchant() async throws {
    let json = """
    {"merchant":"Cafe","date":"2024-06-15","total":12.5,"currency":"USD","items":[]}
    """
    let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
    let receipt: Receipt = try await Extract.from("Cafe total $12.50", using: session)
    #expect(receipt.merchant == "Cafe")
    #expect(receipt.total == Decimal(string: "12.5"))
}
```

Fence stripping and lenient decimals are covered without a live model:

```swift
let fenced = """
Here you go:
\\`\\`\\`json
{"merchant":"X","date":"March 5, 2020","total":"$1,234.50","currency":"USD","items":[]}
\\`\\`\\`
"""
// (In real code use a real triple-backtick fence; stripped automatically.)
let session = ExtractionSession.mock(MockLanguageModel(responses: [fenced]))
let r: Receipt = try await Extract.from("doc", using: session)
#expect(r.total == Decimal(string: "1234.50"))
```

---

## 9. CLI from a script

```bash
export EXTRACT_USE_MOCK=1
swift run extract-cli fixtures/invoice.pdf \
  --schema Examples/schemas/Invoice.swift \
  --mock > /tmp/invoice.json

jq .vendor /tmp/invoice.json
# "Acme Supplies Co."
```

Live path (no `--mock`) uses `ExtractionSession.default`.

---

## 10. SwiftUI: extract then bind to a form

```swift
@MainActor
final class ScannerModel: ObservableObject {
    @Published var receipt: Receipt?
    @Published var error: String?
    @Published var isRunning = false

    func run(url: URL, session: ExtractionSession) {
        isRunning = true
        Task {
            defer { isRunning = false }
            do {
                receipt = try await Extract.from(url, using: session)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
```

See the full polished UI in [`Examples/ReceiptScanner`](../Examples/ReceiptScanner).
