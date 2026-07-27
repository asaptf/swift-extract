# Examples cookbook

Copy-paste oriented recipes. All snippets assume `import Extract` and a configured `session: ExtractionSession`.

**First-class use cases:** receipts · invoices · **identity documents** · emails / free text.

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

## 3. Identity document (passport / ID / driver license)

Recognize structured fields from a passport, national ID, or driver-license photo
(or OCR/plain text). The published schema lives at
[`Examples/schemas/IdentityDocument.swift`](../Examples/schemas/IdentityDocument.swift).

> **Privacy:** Use **synthetic or fully redacted** samples only in demos, fixtures,
> CI, and docs. Never commit real government ID photos or personal data.
> For production ID handling, prefer **on-device** backends (Apple Intelligence / MLX)
> so images and PII stay on the device. LLM extraction is **not** certified KYC or
> NFC ePassport verification. For deterministic MRZ fields with ICAO check digits,
> use `MRZParser` (below).

```swift
import Extract
import Foundation

@Extractable
struct IdentityDocument {
    @Guide("Document kind: passport, nationalId, driverLicense, residencePermit, or other")
    let documentType: DocumentType

    @Guide("Full legal name as printed")
    let fullName: String

    @Guide("Primary document / passport / ID number")
    let documentNumber: String

    @Guide("Date of birth")
    let dateOfBirth: Date

    @Guide("Expiry date if printed; null when absent")
    let expiryDate: Date?

    @Guide("Issue date if printed; null when absent")
    let issueDate: Date?

    @Guide("Nationality as printed, or null")
    let nationality: String?

    @Guide("Issuing authority as printed")
    let issuingAuthority: String?

    @Guide("Sex or gender as printed (e.g. F, M, X); null if absent")
    let sex: String?

    @Guide("Address as printed when present; null otherwise")
    let address: String?

    enum DocumentType: String, Codable, Sendable, CaseIterable {
        case passport, nationalId, driverLicense, residencePermit, other
    }
}
extension IdentityDocument.DocumentType: Extractable {}

// From a photo / scan
let idPhoto = try ExtractionSource.image(url: photoURL)
let document: IdentityDocument = try await Extract.from(idPhoto, using: session)

// From plain text (OCR output or synthetic fixture)
let text = try String(contentsOf: URL(fileURLWithPath: "fixtures/identity_document.txt"))
let fromText: IdentityDocument = try await Extract.from(text, using: session)

print(fromText.fullName, fromText.documentNumber, fromText.documentType)
```

### Deterministic MRZ (ICAO 9303 check digits)

When the document includes a Machine Readable Zone, parse it **without** an LLM.
`MRZParser` reads TD1 / TD2 / TD3 layouts, verifies every ICAO check digit, and
still returns fields when a checksum fails (failed checks are a trust signal, not
a hard error).

```swift
import Extract

// From OCR / plain text that contains an MRZ block somewhere on the page:
let text = try String(contentsOf: URL(fileURLWithPath: "fixtures/identity_document.txt"))
let mrz = try MRZParser.findAndParse(in: text)

print(mrz.surname, mrz.givenNames, mrz.documentNumber)
print(mrz.dateOfBirth.raw, mrz.dateOfBirth.date)
print(mrz.checks.allPassed)  // true only when every defined check digit matched

// Or parse already-isolated MRZ lines:
let isolated = try MRZParser.parse("""
    P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
    L898902C36UTO7408122F1204159ZE184226B<<<<<10
    """)
```

**What this proves and does not prove**

- **Does:** Detects transcription / OCR errors via ICAO 7-3-1 check digits
  (including the composite check). Surfaces structured fields deterministically.
- **Does not:** Prove the document is genuine, replace chip/NFC ePassport
  verification, or verify that the bearer matches the document (not KYC / not
  anti-forgery). Pair with the LLM path above for visual fields the MRZ omits
  (address, issue date, issuing authority name, photo side, etc.).

### Offline CLI (deterministic mock)

```bash
swift run extract-cli fixtures/identity_document.txt \
  --schema Examples/schemas/IdentityDocument.swift \
  --mock
# or: --type IdentityDocument --mock
```

Expected primary fields for the synthetic fixture: full name `JANE ALEXANDRA DOE`,
document number `X12345678`, type `passport`.

Backend note: photo + multi-field ID extraction benefits from a vision-capable cloud
model or a solid local ~3B+ model; pure text from OCR works with smaller models.
See [Backends](Backends.md).

---

## 4. Email / confirmation text

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

## 5. String-backed enums

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

## 6. Repair retries (Instructor-style)

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

## 7. Large documents (chunk + merge)

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

## 8. Locale-aware dates (and multilingual docs)

```swift
var options = ExtractionOptions()
options.locale = Locale(identifier: "en_GB")

// "05/06/2024" tends to be read as 5 June under en_GB
let event: CalendarEvent = try await Extract.from(ukEmail, using: session, options: options)
```

The same option helps non-English documents. Chinese, Arabic, and other scripts work
through Unicode text, Vision OCR, and a multilingual model — set locale for parsing:

```swift
var options = ExtractionOptions()
options.locale = Locale(identifier: "zh_CN")
// or: Locale(identifier: "ar_SA")

let receipt: Receipt = try await Extract.from(photoURL, using: session, options: options)
// e.g. merchant may stay "星巴克"; amounts/dates parse with the locale hint
```

See [README → Languages & scripts](../README.md#languages--scripts) for scope and caveats.

---

## 9. Unit tests without network

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

## 10. CLI from a script

```bash
export EXTRACT_USE_MOCK=1
swift run extract-cli fixtures/invoice.pdf \
  --schema Examples/schemas/Invoice.swift \
  --mock > /tmp/invoice.json

jq .vendor /tmp/invoice.json
# "Acme Supplies Co."

# Identity document (synthetic fixture only)
swift run extract-cli fixtures/identity_document.txt \
  --type IdentityDocument --mock
```

Live path (no `--mock`) uses `ExtractionSession.default`.

---

## 11. SwiftUI: extract then bind to a form

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
