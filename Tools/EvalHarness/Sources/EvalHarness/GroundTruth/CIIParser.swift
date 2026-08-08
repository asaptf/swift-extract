import Foundation

/// Minimal EN16931 CII (Cross Industry Invoice) parser for evaluation ground truth.
///
/// Handles the namespace-qualified UN/CEFACT structure used by Factur-X / ZUGFeRD.
/// Not a full validator — only the fields the harness scores.
public enum CIIParser {
    public static func parse(_ data: Data) throws -> InvoiceGroundTruth {
        let parser = XMLInvoiceParser()
        return try parser.parse(data)
    }
}

// MARK: - Streaming XML parser

private final class XMLInvoiceParser: NSObject, XMLParserDelegate {
    private var truth = InvoiceGroundTruth()
    private var stack: [String] = []
    private var textBuffer = ""
    private var currentLine = InvoiceGroundTruth.LineItem()
    private var inLineItem = false
    private var parseError: Error?

    // Track context for ambiguous local names (ID, Name, …).
    private var path: String { stack.joined(separator: "/") }

    func parse(_ data: Data) throws -> InvoiceGroundTruth {
        let xml = XMLParser(data: data)
        xml.delegate = self
        xml.shouldProcessNamespaces = true
        xml.shouldReportNamespacePrefixes = false
        guard xml.parse() else {
            throw FacturXExtractor.ExtractError.unreadableXML(
                xml.parserError?.localizedDescription ?? "XMLParser failed"
            )
        }
        if let parseError { throw parseError }
        return truth
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localName(elementName, qualifiedName: qualifiedName)
        stack.append(local)
        textBuffer = ""
        if local == "IncludedSupplyChainTradeLineItem" {
            inLineItem = true
            currentLine = InvoiceGroundTruth.LineItem()
        }
        _ = attributeDict
        _ = namespaceURI
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let local = localName(elementName, qualifiedName: qualifiedName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = path

        if inLineItem {
            switch local {
            case "Name" where p.contains("SpecifiedTradeProduct"):
                if currentLine.description == nil, !value.isEmpty {
                    currentLine.description = value
                }
            case "BilledQuantity":
                currentLine.quantity = decimal(value)
            case "LineTotalAmount":
                currentLine.lineTotal = decimal(value)
            case "IncludedSupplyChainTradeLineItem":
                truth.lineItems.append(currentLine)
                inLineItem = false
            default:
                break
            }
        } else {
            switch local {
            case "ID" where p.contains("ExchangedDocument") && !p.contains("TypeCode"):
                // Header invoice number — first ExchangedDocument/ID wins.
                if truth.invoiceNumber == nil, !value.isEmpty, !p.contains("Line") {
                    truth.invoiceNumber = value
                }
            case "DateTimeString" where p.contains("IssueDateTime"):
                if truth.issueDate == nil {
                    truth.issueDate = parseCIIDate(value)
                }
            case "Name" where p.contains("SellerTradeParty") && !p.contains("Line"):
                if truth.sellerName == nil, !value.isEmpty {
                    truth.sellerName = value
                }
            case "InvoiceCurrencyCode":
                if truth.currency == nil, !value.isEmpty {
                    truth.currency = value
                }
            case "GrandTotalAmount":
                if truth.grandTotal == nil {
                    truth.grandTotal = decimal(value)
                }
            case "TaxTotalAmount":
                // Header monetary summation tax total (first wins).
                if truth.taxTotal == nil, p.contains("SpecifiedTradeSettlementHeaderMonetarySummation")
                    || p.contains("ApplicableHeaderTradeSettlement")
                {
                    truth.taxTotal = decimal(value)
                } else if truth.taxTotal == nil {
                    truth.taxTotal = decimal(value)
                }
            default:
                break
            }
        }

        if stack.last == local {
            stack.removeLast()
        } else if let idx = stack.lastIndex(of: local) {
            stack.removeSubrange(idx...)
        }
        textBuffer = ""
        _ = namespaceURI
    }

    private func localName(_ elementName: String, qualifiedName: String?) -> String {
        if elementName.contains(":") {
            return String(elementName.split(separator: ":").last!)
        }
        if let q = qualifiedName, q.contains(":") {
            return String(q.split(separator: ":").last!)
        }
        // With shouldProcessNamespaces, elementName is already local.
        return elementName
    }

    private func decimal(_ raw: String) -> Decimal? {
        let cleaned = raw.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned)
    }

    /// CII format 102 = yyyyMMdd; also accept yyyy-MM-dd.
    private func parseCIIDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = ["yyyyMMdd", "yyyy-MM-dd", "yyyyMMddHHmmss"]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for f in formats {
            formatter.dateFormat = f
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }
}
