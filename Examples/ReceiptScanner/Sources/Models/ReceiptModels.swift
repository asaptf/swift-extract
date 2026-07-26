import Extract
import Foundation

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

/// Editable draft shown after extraction.
struct ReceiptDraft: Equatable {
    var merchant: String
    var date: Date
    var total: String
    var currency: String
    var items: [ItemDraft]
    var rawJSON: String

    struct ItemDraft: Identifiable, Equatable {
        let id: UUID
        var name: String
        var price: String
        var quantity: String

        init(id: UUID = UUID(), name: String, price: String, quantity: String) {
            self.id = id
            self.name = name
            self.price = price
            self.quantity = quantity
        }
    }

    init(from receipt: Receipt, rawJSON: String) {
        merchant = receipt.merchant
        date = receipt.date
        total = "\(receipt.total)"
        currency = receipt.currency
        items = receipt.items.map {
            ItemDraft(
                name: $0.name,
                price: "\($0.price)",
                quantity: $0.quantity.map(String.init) ?? ""
            )
        }
        self.rawJSON = rawJSON
    }

    static let empty = ReceiptDraft(
        merchant: "",
        date: Date(),
        total: "",
        currency: "USD",
        items: [],
        rawJSON: "{}"
    )

    private init(
        merchant: String,
        date: Date,
        total: String,
        currency: String,
        items: [ItemDraft],
        rawJSON: String
    ) {
        self.merchant = merchant
        self.date = date
        self.total = total
        self.currency = currency
        self.items = items
        self.rawJSON = rawJSON
    }
}

enum SampleFixture: String, CaseIterable, Identifiable {
    case invoicePDF
    case receiptPhoto
    case emailScreenshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .invoicePDF: return "Digital invoice (PDF)"
        case .receiptPhoto: return "Paper receipt photo"
        case .emailScreenshot: return "Email confirmation"
        }
    }

    var subtitle: String {
        switch self {
        case .invoicePDF: return "Clean text-layer PDF from Acme Supplies"
        case .receiptPhoto: return "Synthetic café receipt image"
        case .emailScreenshot: return "Order confirmation screenshot"
        }
    }

    var systemImage: String {
        switch self {
        case .invoicePDF: return "doc.richtext"
        case .receiptPhoto: return "camera.viewfinder"
        case .emailScreenshot: return "envelope.open"
        }
    }

    var resourceName: String {
        switch self {
        case .invoicePDF: return "invoice"
        case .receiptPhoto: return "receipt"
        case .emailScreenshot: return "email_screenshot"
        }
    }

    var resourceExtension: String {
        switch self {
        case .invoicePDF: return "pdf"
        case .receiptPhoto, .emailScreenshot: return "png"
        }
    }

    var url: URL? {
        // SPM executable uses Bundle.module; the Xcode app target uses Bundle.main.
        let bundles: [Bundle] = {
            #if SWIFT_PACKAGE
                return [Bundle.module, .main]
            #else
                return [.main]
            #endif
        }()
        for bundle in bundles {
            if let url = bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: "Fixtures"
            ) {
                return url
            }
            if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) {
                return url
            }
            // XcodeGen folder resources may land under a nested path.
            if let root = bundle.resourceURL?
                .appendingPathComponent("Fixtures", isDirectory: true)
                .appendingPathComponent("\(resourceName).\(resourceExtension)")
            {
                if FileManager.default.fileExists(atPath: root.path) {
                    return root
                }
            }
        }
        return nil
    }
}
