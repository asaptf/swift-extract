import Foundation

/// Geometry-path collection builder: one mapping call, then deterministic rows.
///
/// Only the first array-of-objects in the target schema is in scope. Candidate
/// tables prefer ``ExtractedTable/isLineItemShaped``; when none match, any
/// ``ExtractedTable/isGeometryCollectionCandidate`` is offered so a two-item
/// invoice is not silently sent down the model path. Several candidates stay
/// in the mapping prompt — the model chooses; we do not pick by size.
enum GeometryLineItems {
    struct Overlay: Sendable {
        var path: [String]
        var itemsJSON: String
    }

    enum Preparation: Sendable {
        case notRequested
        case used(overlay: Overlay, mappingAttempts: Int)
        case fallback(reason: String, mappingAttempts: Int)

        var collectionSource: CollectionSource {
            switch self {
            case .notRequested:
                return .model
            case .used:
                return .geometry
            case .fallback(let reason, _):
                return .geometryFallback(reason: reason)
            }
        }

        var mappingAttempts: Int {
            switch self {
            case .notRequested:
                return 0
            case .used(_, let attempts), .fallback(_, let attempts):
                return attempts
            }
        }

        var overlay: Overlay? {
            if case .used(let overlay, _) = self { return overlay }
            return nil
        }
    }

    /// Tables offered to the mapping call, in document order.
    static func candidates(in tables: [ExtractedTable]) -> [ExtractedTable] {
        let shaped = tables.filter(\.isLineItemShaped)
        if !shaped.isEmpty { return shaped }
        return tables.filter(\.isGeometryCollectionCandidate)
    }

    static func prepare(
        schema: ExtractionSchema,
        tables: [ExtractedTable],
        using session: ExtractionSession,
        options: ExtractionOptions
    ) async throws -> Preparation {
        guard options.lineItemSource == .geometry else {
            return .notRequested
        }
        guard let collection = schema.firstObjectCollection else {
            return .fallback(
                reason: "schema has no array-of-objects collection",
                mappingAttempts: 0
            )
        }
        let offered = candidates(in: tables)
        guard !offered.isEmpty else {
            return .fallback(reason: "no qualifying table", mappingAttempts: 0)
        }

        let user = PromptBuilder.columnMappingPrompt(
            collectionPath: collection.dottedPath,
            itemSchema: collection.itemSchema,
            candidates: offered
        )
        let raw = try await session.generate(
            system: PromptBuilder.columnMappingSystemInstructions,
            user: user,
            temperature: options.resolvedTemperature(session: session),
            schema: mappingResponseSchema
        )

        switch parseMapping(
            raw,
            candidates: offered,
            itemSchema: collection.itemSchema
        ) {
        case .failure(let error):
            return .fallback(reason: error.reason, mappingAttempts: 1)
        case .success(let mapping):
            let table = offered[mapping.tableIndex]
            let built = buildItems(
                table: table,
                columns: mapping.columns,
                itemSchema: collection.itemSchema,
                locale: options.locale
            )
            if built.droppedRequiredRow {
                return .fallback(
                    reason: "required field missing on a data row",
                    mappingAttempts: 1
                )
            }
            let items = built.items
            guard !items.isEmpty else {
                return .fallback(
                    reason: "no usable data rows after mapping",
                    mappingAttempts: 1
                )
            }
            guard let itemsJSON = jsonArrayString(items) else {
                return .fallback(
                    reason: "mapped collection failed to encode",
                    mappingAttempts: 1
                )
            }
            return .used(
                overlay: Overlay(path: collection.path, itemsJSON: itemsJSON),
                mappingAttempts: 1
            )
        }
    }

    /// Replace the collection at `overlay.path` on a model JSON object.
    static func splice(
        _ raw: String,
        overlay: Overlay,
        expectedRoot: ExtractionSchema.SchemaType
    ) throws -> String {
        let cleaned = JSONFenceStripper.strip(raw, expectedRoot: expectedRoot)
        guard let data = cleaned.data(using: .utf8) else {
            throw ExtractionError.internalError("Geometry splice: JSON is not valid UTF-8")
        }
        let parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard var object = parsed as? [String: Any] else {
            throw ExtractionError.internalError("Geometry splice: expected a JSON object")
        }
        guard let itemsData = overlay.itemsJSON.data(using: .utf8),
            let items = try JSONSerialization.jsonObject(with: itemsData) as? [Any]
        else {
            throw ExtractionError.internalError("Geometry splice: overlay items are not a JSON array")
        }
        setValue(items, on: &object, path: overlay.path)
        guard JSONSerialization.isValidJSONObject(object),
            let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let string = String(data: out, encoding: .utf8)
        else {
            throw ExtractionError.internalError("Geometry splice: could not re-encode JSON")
        }
        return string
    }

    // MARK: - Mapping

    struct ColumnMapping: Equatable {
        var tableIndex: Int
        var columns: [String: Int]
    }

    struct MappingError: Error, Equatable {
        var reason: String
    }

    static func parseMapping(
        _ raw: String,
        candidates: [ExtractedTable],
        itemSchema: ExtractionSchema
    ) -> Result<ColumnMapping, MappingError> {
        let cleaned = JSONFenceStripper.strip(raw, expectedRoot: .object)
        guard let data = cleaned.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .failure(MappingError(reason: "column mapping failed: response is not a JSON object"))
        }

        let tableIndex: Int
        switch resolveTableIndex(object["table"] ?? object["tableIndex"], count: candidates.count)
        {
        case .failure(let reason):
            return .failure(reason)
        case .success(let index):
            tableIndex = index
        }

        let columnCount = candidates[tableIndex].columnCount
        let knownFields = Set((itemSchema.properties ?? [:]).keys)
        guard
            let columnsValue = object["columns"] as? [String: Any]
                ?? object["mapping"] as? [String: Any]
        else {
            return .failure(MappingError(reason: "column mapping failed: missing columns object"))
        }

        var columns: [String: Int] = [:]
        for (field, rawIndex) in columnsValue {
            guard knownFields.contains(field) else { continue }
            guard let index = intValue(rawIndex) else {
                return .failure(
                    MappingError(
                        reason: "column mapping failed: column for `\(field)` is not an integer"
                    )
                )
            }
            guard index >= 0, index < columnCount else {
                return .failure(
                    MappingError(
                        reason:
                            "mapping named column \(index) which is out of range (table has \(columnCount) columns)"
                    )
                )
            }
            columns[field] = index
        }

        if columns.isEmpty {
            return .failure(MappingError(reason: "column mapping failed: no known fields were mapped"))
        }

        let required = itemSchema.required ?? []
        for field in required where columns[field] == nil {
            return .failure(
                MappingError(reason: "column mapping failed: omitted required field `\(field)`")
            )
        }

        return .success(ColumnMapping(tableIndex: tableIndex, columns: columns))
    }

    private static func resolveTableIndex(_ raw: Any?, count: Int) -> Result<Int, MappingError> {
        if raw == nil {
            return count == 1
                ? .success(0)
                : .failure(MappingError(reason: "column mapping failed: table index missing"))
        }
        guard let value = intValue(raw) else {
            return .failure(MappingError(reason: "column mapping failed: table index is not an integer"))
        }
        let index = value == 0 ? 0 : value - 1
        guard index >= 0, index < count else {
            return .failure(MappingError(reason: "mapping selected table \(value) which is out of range"))
        }
        return .success(index)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let string = raw as? String {
            return Int(string.trimmingCharacters(in: .whitespaces))
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let value = number.doubleValue
            guard value.rounded(.towardZero) == value,
                value >= Double(Int.min),
                value <= Double(Int.max)
            else {
                return nil
            }
            return Int(value)
        }
        if let int = raw as? Int { return int }
        return nil
    }

    // MARK: - Rows

    struct BuiltItems {
        var items: [[String: Any]]
        var droppedRequiredRow: Bool
    }

    /// Parse each data row into a JSON object using lenient cell decoding.
    static func buildItems(
        table: ExtractedTable,
        columns: [String: Int],
        itemSchema: ExtractionSchema,
        locale: Locale?
    ) -> BuiltItems {
        let properties = itemSchema.properties ?? [:]
        let required = Set(itemSchema.required ?? [])
        var items: [[String: Any]] = []
        var droppedRequiredRow = false
        for row in 0..<table.rowCount {
            if let header = table.headerRowIndex, row == header { continue }
            var texts: [String] = []
            for column in 0..<table.columnCount {
                if let text = table.text(row: row, column: column) {
                    texts.append(text)
                }
            }
            if isFooterRow(texts) { continue }

            var object: [String: Any] = [:]
            for (field, column) in columns {
                guard let fieldSchema = properties[field] else { continue }
                let raw = table.text(row: row, column: column) ?? ""
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let value = typedJSONValue(trimmed, schema: fieldSchema, locale: locale) {
                    object[field] = value
                }
            }
            if object.isEmpty { continue }
            if required.contains(where: { object[$0] == nil }) {
                droppedRequiredRow = true
                continue
            }
            items.append(object)
        }
        return BuiltItems(items: items, droppedRequiredRow: droppedRequiredRow)
    }

    /// Typed JSON value for one cell, using the same lenient parsers as decode.
    static func typedJSONValue(
        _ text: String,
        schema: ExtractionSchema,
        locale: Locale?
    ) -> Any? {
        switch schema.type {
        case .string:
            if schema.format == "date-time" || schema.format == "date" {
                guard let date = LenientDecoding.parseDate(text, locale: locale) else {
                    return nil
                }
                return isoDateString(date)
            }
            if let allowed = schema.enumValues, !allowed.contains(text) {
                return nil
            }
            return text
        case .number:
            guard let decimal = LenientDecoding.parseDecimal(text, locale: locale) else {
                return nil
            }
            return NSDecimalNumber(decimal: decimal)
        case .integer:
            guard let decimal = LenientDecoding.parseDecimal(text, locale: locale) else {
                return nil
            }
            var rounded = Decimal()
            var mutable = decimal
            NSDecimalRound(&rounded, &mutable, 0, .plain)
            var delta = decimal - rounded
            if delta < 0 { delta = -delta }
            let tolerance = Decimal(sign: .plus, exponent: -3, significand: 1)
            guard delta <= tolerance else { return nil }
            return NSDecimalNumber(decimal: rounded).intValue as NSNumber
        case .boolean:
            let folded = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch folded {
            case "true", "yes", "y", "1": return true
            case "false", "no", "n", "0": return false
            default: return nil
            }
        case .null:
            return NSNull()
        case .object, .array:
            return nil
        }
    }

    /// Totals / tax / balance rows are not line items.
    static func isFooterRow(_ texts: [String]) -> Bool {
        for text in texts {
            let folded =
                text
                .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                .lowercased()
            let scalars = folded.unicodeScalars.map { scalar -> Character in
                CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
            }
            let token = String(scalars).split(separator: " ").joined()
            if footerTokens.contains(token) { return true }
        }
        return false
    }

    private static let footerTokens: Set<String> = [
        "total", "subtotal", "tax", "vat", "sum", "balance",
        "grandtotal", "amountdue",
    ]

    private static let mappingResponseSchema = ExtractionSchema.object(
        title: "ColumnMapping",
        properties: [
            "table": .integer(description: "1-based candidate table number"),
            "columns": .object(
                description: "Map of element field name to 0-based column index",
                properties: [:],
                required: []
            ),
        ],
        required: ["table", "columns"]
    )

    private static func isoDateString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        if let year = components.year, let month = components.month, let day = components.day,
            hour == 0, minute == 0, second == 0
        {
            return String(format: "%04d-%02d-%02d", year, month, day)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func jsonArrayString(_ items: [[String: Any]]) -> String? {
        guard JSONSerialization.isValidJSONObject(items),
            let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func setValue(_ value: Any, on object: inout [String: Any], path: [String]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            object[key] = value
            return
        }
        var child = object[key] as? [String: Any] ?? [:]
        setValue(value, on: &child, path: Array(path.dropFirst()))
        object[key] = child
    }
}
