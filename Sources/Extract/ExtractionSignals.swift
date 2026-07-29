import Foundation

// MARK: - Public signal types

/// How a single extracted leaf relates to the source document text.
///
/// These are **informational signals, not a calibrated confidence score**.
/// There is no probability attached; do not threshold them for auto-accept.
///
/// - ``verbatim``: the value appears literally in the source.
/// - ``normalized``: the value appears after case / whitespace / diacritic / punctuation
///   folding (punctuation is treated as word boundaries so comma-joined multi-line
///   fields still match).
/// - ``reformatted``: the leaf was type-converted (date, number, bool, null), so a
///   literal substring match is not meaningful, *or* a date/number encoding was not
///   found as text (still not proof of error).
/// - ``absent``: not found in the source text — the model may have inferred or
///   hallucinated the value. Prompt to look, not proof of error.
///
/// ## When ``absent`` can fire
///
/// In practice **``absent`` only ever fires for string leaves**. Numeric and date-time
/// leaves never report ``absent``: when no source match is found they return
/// ``reformatted`` instead.
///
/// - **Numbers:** deliberate and conservative. Small integers like `quantity: 2` would
///   otherwise match spuriously throughout free text, so a fabricated number is never
///   flagged as ``absent``.
/// - **Dates:** the model routinely rewrites human forms (`15 MAR 1990`) to ISO
///   (`1990-03-15`); treating unmatched dates as ``absent`` would make the signal noise.
/// - **Booleans / nulls:** not groundable against free text; always ``reformatted``.
public enum Grounding: String, Sendable, Equatable, CaseIterable {
    /// Found as an exact substring of the source text.
    case verbatim
    /// Found after normalizing case, whitespace, diacritics, and punctuation.
    case normalized
    /// Type conversion makes a literal match meaningless (dates, decimals, bools, nulls),
    /// or the canonical encoding was not located as text.
    ///
    /// Numeric and date leaves that fail to match the source also land here — never
    /// ``absent``. See the ``Grounding`` type docs for why.
    case reformatted
    /// Not found in the source text (inferred or hallucinated). Look before trusting.
    ///
    /// Only string leaves produce this case. Numbers and dates use ``reformatted`` when
    /// unmatched; see the ``Grounding`` type docs.
    case absent
}

/// Grounding evidence for one leaf field of an extraction result.
public struct FieldSignal: Sendable, Equatable {
    /// Dotted / indexed path, e.g. `total`, `items[0].name`.
    public let path: String
    /// How this leaf relates to the source document text.
    public let grounding: Grounding

    public init(path: String, grounding: Grounding) {
        self.path = path
        self.grounding = grounding
    }
}

/// Explainable extraction evidence (not a confidence score).
///
/// Produced on every ``Extract/detailed(from:as:using:options:)`` run. Each entry in
/// ``fields`` is an independently checkable fact about one leaf. There is **no**
/// aggregate probability; ``absent`` means "not found in the source text", which is a
/// prompt to inspect, not proof of error.
///
/// **Limitation:** ``absentFieldPaths`` (and ``Grounding/absent`` generally) only ever
/// lists **string** leaves. Fabricated numbers and unmatched dates are reported as
/// ``Grounding/reformatted``, not ``absent`` — see ``Grounding``.
public struct ExtractionSignals: Sendable, Equatable {
    /// Total generation attempts used for this result (including repairs / merge).
    public let attempts: Int
    /// Number of document chunks that contributed to the result.
    public let chunksUsed: Int
    /// Per-leaf grounding facts, in schema / encode walk order.
    public let fields: [FieldSignal]

    public init(attempts: Int, chunksUsed: Int, fields: [FieldSignal]) {
        self.attempts = attempts
        self.chunksUsed = chunksUsed
        self.fields = fields
    }

    /// Paths whose values were not found in the source text.
    ///
    /// Only string leaves appear here. Numeric and date fields that fail to match are
    /// ``Grounding/reformatted``, not ``absent`` — see ``Grounding``.
    public var absentFieldPaths: [String] {
        fields.filter { $0.grounding == .absent }.map(\.path)
    }
}

// MARK: - Computation

/// Builds ``ExtractionSignals`` by encoding the value and walking it with the schema.
enum FieldGrounding {
    /// Per-`compute` call counters (thread-safe for concurrent tests).
    final class ComputeStats: @unchecked Sendable {
        private let lock = NSLock()
        private var _normalizeForSearchCalls = 0
        private var _numericSkeletonCalls = 0

        var normalizeForSearchCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _normalizeForSearchCalls
        }

        var numericSkeletonCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _numericSkeletonCalls
        }

        func recordNormalize() {
            lock.lock()
            _normalizeForSearchCalls += 1
            lock.unlock()
        }

        func recordSkeleton() {
            lock.lock()
            _numericSkeletonCalls += 1
            lock.unlock()
        }
    }

    /// Precomputed source views shared across every leaf of one ``compute`` call.
    ///
    /// Without this, each string leaf re-folds the full source (case / diacritic /
    /// punctuation) and each number leaf rebuilds the numeric skeleton — making
    /// mandatory signal generation O(N×M) and able to appear hung on large
    /// chunk-merged documents.
    private struct SourceIndex {
        let raw: String
        let normalized: String
        let numericSkeleton: String
        let stats: ComputeStats?

        init(sourceText: String, stats: ComputeStats?) {
            raw = sourceText
            self.stats = stats
            normalized = FieldGrounding.normalizeForSearch(sourceText, stats: stats)
            numericSkeleton = FieldGrounding.numericSkeleton(sourceText, stats: stats)
        }
    }

    /// Compute per-leaf grounding of `value` against `sourceText`.
    static func compute<T: Extractable>(
        value: T,
        sourceText: String,
        attempts: Int,
        chunksUsed: Int
    ) -> ExtractionSignals {
        compute(value: value, sourceText: sourceText, attempts: attempts, chunksUsed: chunksUsed, stats: nil)
    }

    /// Package-test helper: same as ``compute(value:sourceText:attempts:chunksUsed:)``
    /// but records how many times source-scale normalisations ran.
    static func compute<T: Extractable>(
        value: T,
        sourceText: String,
        attempts: Int,
        chunksUsed: Int,
        stats: ComputeStats?
    ) -> ExtractionSignals {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(encodeDate)
        encoder.outputFormatting = []

        guard let data = try? encoder.encode(value),
            let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return ExtractionSignals(attempts: attempts, chunksUsed: chunksUsed, fields: [])
        }

        let source = SourceIndex(sourceText: sourceText, stats: stats)
        var fields: [FieldSignal] = []
        walk(
            json: root,
            schema: T.extractionSchema,
            path: "",
            source: source,
            fields: &fields
        )
        return ExtractionSignals(attempts: attempts, chunksUsed: chunksUsed, fields: fields)
    }

    // MARK: Tree walk

    private static func walk(
        json: Any,
        schema: ExtractionSchema,
        path: String,
        source: SourceIndex,
        fields: inout [FieldSignal]
    ) {
        switch schema.type {
        case .object:
            guard let object = json as? [String: Any] else { return }
            let properties = schema.properties ?? [:]
            let order = schema.propertyOrder ?? Array(properties.keys).sorted()
            var seen = Set<String>()
            for key in order {
                guard let childSchema = properties[key] else { continue }
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                // Macro-generated `encodeIfPresent` omits nil optionals entirely.
                // Documented behaviour is that null leaves are `reformatted`; emit
                // an explicit row so callers can distinguish considered-null from
                // a missing signal.
                guard let childJSON = object[key], !(childJSON is NSNull) else {
                    fields.append(FieldSignal(path: childPath, grounding: .reformatted))
                    seen.insert(key)
                    continue
                }
                seen.insert(key)
                walk(json: childJSON, schema: childSchema, path: childPath, source: source, fields: &fields)
            }
            for (key, childJSON) in object where !seen.contains(key) {
                guard let childSchema = properties[key] else { continue }
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if childJSON is NSNull {
                    fields.append(FieldSignal(path: childPath, grounding: .reformatted))
                } else {
                    walk(json: childJSON, schema: childSchema, path: childPath, source: source, fields: &fields)
                }
            }

        case .array:
            guard let array = json as? [Any] else { return }
            let itemSchema = schema.items ?? .string()
            for (index, element) in array.enumerated() {
                let childPath = "\(path)[\(index)]"
                walk(json: element, schema: itemSchema, path: childPath, source: source, fields: &fields)
            }

        case .string:
            if schema.format == "date-time" {
                fields.append(FieldSignal(path: path, grounding: dateGrounding(json: json, source: source)))
            } else if let string = json as? String {
                fields.append(FieldSignal(path: path, grounding: stringGrounding(string, source: source)))
            } else {
                // Encoded non-string for a string schema (unusual) — treat as reformatted.
                fields.append(FieldSignal(path: path, grounding: .reformatted))
            }

        case .number, .integer:
            fields.append(FieldSignal(path: path, grounding: numberGrounding(json: json, source: source)))

        case .boolean:
            // Booleans are not groundable against free text; report reformatted.
            fields.append(FieldSignal(path: path, grounding: .reformatted))

        case .null:
            // Explicit null is not groundable; report reformatted.
            fields.append(FieldSignal(path: path, grounding: .reformatted))
        }
    }

    // MARK: Leaf grounding

    private static func stringGrounding(_ value: String, source: SourceIndex) -> Grounding {
        if value.isEmpty {
            // Empty string has no informative substring; treat as absent.
            return .absent
        }
        if source.raw.contains(value) {
            return .verbatim
        }
        let normalizedValue = normalizeForSearch(value, stats: source.stats)
        if !normalizedValue.isEmpty, source.normalized.contains(normalizedValue) {
            return .normalized
        }
        return .absent
    }

    private static func dateGrounding(json: Any, source: SourceIndex) -> Grounding {
        // Prefer string encodings produced by our custom date encoder.
        if let string = json as? String {
            if source.raw.contains(string) {
                return .verbatim
            }
            // Also try date-only prefix of an ISO timestamp.
            if string.count >= 10 {
                let prefix = String(string.prefix(10))
                if prefix.contains("-"), source.raw.contains(prefix) {
                    return .verbatim
                }
            }
            let normalized = normalizeForSearch(string, stats: source.stats)
            if !normalized.isEmpty, source.normalized.contains(normalized) {
                return .normalized
            }
        } else if let number = json as? NSNumber {
            let string = number.stringValue
            if source.raw.contains(string) {
                return .verbatim
            }
        }
        // Schema-declared date-time: model reformats human dates → ISO. Not absent.
        return .reformatted
    }

    private static func numberGrounding(json: Any, source: SourceIndex) -> Grounding {
        let candidates = numberSearchCandidates(json)
        for candidate in candidates where !candidate.isEmpty {
            if source.raw.contains(candidate) {
                return .verbatim
            }
        }
        // Currency / grouping variants: compare digit+separator runs (signs kept).
        for candidate in candidates {
            let skeleton = numericSkeleton(candidate, stats: source.stats)
            if !skeleton.isEmpty, source.numericSkeleton.contains(skeleton) {
                return .normalized
            }
        }
        // Unmatched numbers are reformatted, never absent. Small integers would match
        // spuriously across free text if we flagged missing digits as absent, so a
        // fabricated number is intentionally never reported as absent. See Grounding docs.
        return .reformatted
    }

    private static func numberSearchCandidates(_ json: Any) -> [String] {
        var result: [String] = []
        if let number = json as? NSNumber {
            let string = number.stringValue
            result.append(string)
            // Trailing-zero / two-decimal variants for money-like values.
            let doubleValue = number.doubleValue
            if doubleValue == doubleValue.rounded(.towardZero) {
                result.append(String(format: "%.0f", doubleValue))
                result.append(String(format: "%.2f", doubleValue))
            } else {
                result.append(String(format: "%.2f", doubleValue))
                result.append(String(format: "%.1f", doubleValue))
            }
        } else if let string = json as? String {
            result.append(string)
        }
        // Deduplicate while preserving order.
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Digits, decimal separators, and leading-minus signs for numeric containment.
    ///
    /// Signs must participate: stripping them labels extracted `-12.5` as
    /// ``Grounding/normalized`` against source text `Total: 12.50`. Only a minus
    /// immediately before a digit is kept, so hyphenated prose does not pollute
    /// the skeleton.
    private static func numericSkeleton(_ text: String, stats: ComputeStats? = nil) -> String {
        stats?.recordSkeleton()
        var out = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if (48...57).contains(scalar.value) || scalar == "." || scalar == "," {
                out.unicodeScalars.append(scalar)
            } else if isMinusScalar(scalar),
                index + 1 < scalars.count,
                (48...57).contains(scalars[index + 1].value)
            {
                // Normalise every Unicode minus to ASCII so skeletons compare equal.
                out.append("-")
            }
            index += 1
        }
        return out.replacingOccurrences(of: ",", with: "")
    }

    private static func isMinusScalar(_ scalar: UnicodeScalar) -> Bool {
        // ASCII hyphen-minus, Unicode minus, small hyphen-minus, fullwidth hyphen-minus.
        scalar == "-" || scalar == "\u{2212}" || scalar == "\u{FE63}" || scalar == "\u{FF0D}"
    }

    // MARK: Normalization

    /// Case-fold, strip diacritics, treat punctuation as word boundaries, collapse whitespace.
    ///
    /// **Punctuation choice:** non-alphanumeric characters (commas, hyphens, periods, etc.)
    /// become spaces rather than being deleted or kept. Kept punctuation caused false
    /// ``Grounding/absent`` signals on multi-line fields — e.g. an address the model returns
    /// as `"123 SAMPLE STREET, APT 4B, SPRINGFIELD, IL 62701"` against a source that prints
    /// the same content across newlines without those commas. Deleting punctuation without a
    /// separator would glue tokens (`"U.S."` → `"us"`) into accidental substrings; mapping
    /// it to spaces preserves token boundaries while still equating comma-joined and
    /// newline-separated forms. Only Unicode letters and digits survive as content.
    static func normalizeForSearch(_ text: String, stats: ComputeStats? = nil) -> String {
        stats?.recordNormalize()
        let folded =
            text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            // Whitespace and punctuation both become spaces (word boundaries).
            return " "
        }
        let collapsed =
            String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed
    }

    // MARK: Date encoding (stable ISO for walk + optional literal match)

    private static func encodeDate(_ date: Date, _ encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = components.second ?? 0
        if let year = components.year, let month = components.month, let day = components.day,
            hour == 0, minute == 0, second == 0
        {
            try container.encode(
                String(format: "%04d-%02d-%02d", year, month, day)
            )
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            try container.encode(formatter.string(from: date))
        }
    }
}
