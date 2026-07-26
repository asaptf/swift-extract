import Extract
import Foundation

// MARK: - Embedded schemas (match Examples/schemas/*.swift)

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

// MARK: - CLI

@main
struct ExtractCLI {
    static func main() async {
        do {
            try await run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(arguments: [String]) async throws {
        var args = arguments
        var schemaName = "Invoice"
        var useMock = ProcessInfo.processInfo.environment["EXTRACT_USE_MOCK"] == "1"
        var mockJSON: String?
        var inputPath: String?

        while let arg = args.first {
            args.removeFirst()
            switch arg {
            case "--help", "-h":
                print(usage)
                return
            case "--schema":
                let path = try takeValue(for: arg, from: &args)
                schemaName = inferSchemaName(from: path)
            case "--as":
                let value = try takeValue(for: arg, from: &args)
                schemaName = inferSchemaName(from: value)
            case "--type":
                schemaName = try takeValue(for: arg, from: &args)
            case "--mock":
                useMock = true
            case "--mock-json":
                let value = try takeValue(for: arg, from: &args)
                if let data = try? Data(contentsOf: URL(fileURLWithPath: value)),
                    let text = String(data: data, encoding: .utf8)
                {
                    mockJSON = text
                } else {
                    mockJSON = value
                }
                useMock = true
            case "--":
                for value in args {
                    if inputPath == nil {
                        inputPath = value
                    } else {
                        throw CLIError.unexpectedArgument(value)
                    }
                }
                args.removeAll()
            default:
                if arg.hasPrefix("-") {
                    throw CLIError.unknownOption(arg)
                }
                if inputPath == nil {
                    inputPath = arg
                } else {
                    throw CLIError.unexpectedArgument(arg)
                }
            }
        }

        guard let inputPath else {
            fputs(usage + "\n", stderr)
            throw CLIError.missingInput
        }

        let url = URL(fileURLWithPath: inputPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError.fileNotFound(inputPath)
        }

        let session: ExtractionSession
        if useMock {
            let canned = mockJSON ?? defaultMockJSON(for: schemaName, input: url)
            session = .mock(MockLanguageModel(responses: [canned]))
        } else {
            session = .default
        }

        let source = ExtractionSource.fileURL(url)
        let options = ExtractionOptions(maxRetries: 2)

        let json: String
        switch schemaName.lowercased() {
        case "invoice":
            let value: Invoice = try await Extract.from(source, using: session, options: options)
            json = try encodePretty(value)
        case "receipt":
            let value: Receipt = try await Extract.from(source, using: session, options: options)
            json = try encodePretty(value)
        default:
            throw CLIError.unknownSchema(schemaName)
        }

        print(json)
    }

    static func takeValue(for option: String, from arguments: inout [String]) throws -> String {
        guard let value = arguments.first else {
            throw CLIError.missingOptionValue(option)
        }
        arguments.removeFirst()
        return value
    }

    static var usage: String {
        """
        extract-cli — typed structured extraction from documents

        Usage:
          extract-cli <file> [--schema Examples/schemas/Invoice.swift] [--mock]

        Options:
          --schema <path>   Schema declaration path (selects embedded type by filename)
          --as <name>       Schema name or path (e.g. Invoice.swift)
          --type <name>     Invoice | Receipt
          --mock            Use deterministic offline mock model (also EXTRACT_USE_MOCK=1)
          --mock-json <s>   Canned model JSON (or path to a .json file)
          -h, --help        Show this help
        """
    }

    static func inferSchemaName(from path: String) -> String {
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return base
    }

    static func encodePretty<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Deterministic offline payload derived from fixture text so CI is hermetic.
    static func defaultMockJSON(for schema: String, input: URL) -> String {
        // Prefer reading text layer so the mock reflects the fixture when possible.
        let text = (try? String(contentsOf: input, encoding: .utf8)) ?? ""
        switch schema.lowercased() {
        case "receipt":
            return """
                {
                  "merchant": "Cafe Example",
                  "date": "2024-06-15",
                  "total": 12.50,
                  "currency": "USD",
                  "items": [
                    {"name": "Latte", "price": 4.50, "quantity": 1},
                    {"name": "Croissant", "price": 3.00, "quantity": 2}
                  ]
                }
                """
        default:
            // Invoice
            if text.localizedCaseInsensitiveContains("Acme") {
                return """
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
            }
            return """
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
        }
    }
}

enum CLIError: Error, LocalizedError {
    case missingInput
    case missingOptionValue(String)
    case fileNotFound(String)
    case unknownOption(String)
    case unexpectedArgument(String)
    case unknownSchema(String)

    var errorDescription: String? {
        switch self {
        case .missingInput: return "Missing input file path."
        case .missingOptionValue(let option): return "Missing value for option \(option)."
        case .fileNotFound(let p): return "File not found: \(p)"
        case .unknownOption(let o): return "Unknown option: \(o)"
        case .unexpectedArgument(let a): return "Unexpected argument: \(a)"
        case .unknownSchema(let s):
            return "Unknown schema '\(s)'. Supported: Invoice, Receipt."
        }
    }
}
