import Foundation

/// One scalar (or type) disagreement found while deterministically merging chunk partials.
///
/// Values are compact JSON fragments of the competing occurrences, in chunk order
/// (first distinct value first). Recorded only when candidates are **equally grounded**
/// (genuine conflict). A better-grounded value silently replaces a worse one — no
/// confidence score is attached.
public struct MergeConflict: Sendable, Equatable {
    /// Dotted path from the root object, e.g. `total`, `seller.name`.
    public let path: String
    /// Competing values as compact JSON (e.g. `99.99`, `"Acme"`, `true`, `null`).
    public let values: [String]

    public init(path: String, values: [String]) {
        self.path = path
        self.values = values
    }
}

/// Deterministic structural merge of partial JSON objects produced by per-chunk extraction.
///
/// Merging already-decoded partials is a tree problem, not a generation problem:
/// objects merge key-wise, arrays concatenate then de-duplicate equal entries and drop
/// entries whose text is not grounded in the full document, and disagreeing scalars are
/// arbitrated by **grounding rank** against each candidate's own chunk text.
///
/// ## Scalar arbitration (grounding as arbiter)
///
/// Among disagreeing scalar candidates, prefer the value that is better grounded in
/// the **full document** (same source text public ``FieldGrounding`` signals use after
/// a chunked run — not a per-chunk slice):
///
/// 1. ``FieldGrounding/MergeRank/verbatim``
/// 2. ``FieldGrounding/MergeRank/normalized``
/// 3. ``FieldGrounding/MergeRank/ungrounded``
///
/// Only equal ranks are a genuine conflict: keep the **first** equally-grounded value
/// and record a ``MergeConflict``. Ungrounded candidates lose to grounded ones rather
/// than winning on position. Null still yields to non-null without conflict.
///
/// Ranking against the full document (rather than each partial’s chunk) avoids demoting
/// a correct early value that the model emitted before its supporting text appeared in
/// a later slice, while still letting a document-supported value beat a pure
/// hallucination. It does **not** encode layout rules such as “totals are at the bottom”.
///
/// **Short numerics:** bare 1–2 digit integers match almost any text, so merge ranking
/// treats a numeric candidate as grounded only when it is *distinctive* (digit count
/// ≥ 3, or contains a decimal separator). See
/// ``FieldGrounding/isDistinctiveNumericCandidate(_:)``. Public per-leaf ``Grounding``
/// signals are unchanged.
///
/// ## Array entry filter
///
/// After concatenation, drop entries whose text cannot be supported by the full
/// document (see ``FieldGrounding/isArrayEntryTextGrounded(_:in:)``): a string leaf
/// must match verbatim/normalized **or** clear token coverage. Pure numeric / bool
/// entries (no text to ground) are kept so legitimate bare rows are not deleted.
/// Remaining equal entries are then de-duplicated (see below).
///
/// ## Array de-duplication rule
///
/// After filtering, two array elements are considered the same entry when they are
/// **structurally equal after the same light normalisation the lenient decoder applies
/// before type conversion**:
///
/// - strings: trim leading/trailing whitespace and newlines
/// - numbers / bools / null: exact JSON equality
/// - objects / arrays: recursive structural equality under the same rules
///
/// Only full-entry equality de-dupes. Two line items that share a description but differ
/// in amount (or any other field) are kept. Legitimately repeated identical rows in the
/// source document can collapse if every field matches after trim — that is the accepted
/// tradeoff for suppressing the common cross-chunk duplicate of the same line.
enum ChunkJSONMerger {
    struct Outcome: Sendable {
        /// Merged root object as a JSON string (always a JSON object, possibly empty).
        let json: String
        let conflicts: [MergeConflict]
    }

    /// Merge partial JSON strings into one object tree.
    ///
    /// - Parameters:
    ///   - partialJSONObjects: Raw model outputs (one per chunk), in chunk order.
    ///   - fullDocumentText: Full document text used to rank scalar candidates and to
    ///     filter ungrounded array entries. Empty / omitted → all scalars ungrounded
    ///     (first-wins among equals) and no array grounding filter (de-dupe still runs).
    ///
    /// Partials that are not JSON, are root `null`, or are a non-object root contribute
    /// nothing (they are skipped). When every partial is skipped, the result is `{}`.
    static func merge(
        partialJSONObjects: [String],
        fullDocumentText: String = ""
    ) -> Outcome {
        var conflicts: [MergeConflict] = []
        var root: [String: Any] = [:]
        /// Best merge-rank seen for each scalar path (winner's rank).
        var scalarRanks: [String: FieldGrounding.MergeRank] = [:]

        for partial in partialJSONObjects {
            guard let object = parseObjectContributing(partial) else { continue }
            root = mergeObjects(
                root,
                object,
                path: "",
                sourceText: fullDocumentText,
                scalarRanks: &scalarRanks,
                conflicts: &conflicts
            )
        }

        if !fullDocumentText.isEmpty {
            root = filterArrayEntries(root, fullDocumentText: fullDocumentText) as? [String: Any] ?? root
        }

        let json = serializeObject(root) ?? "{}"
        return Outcome(json: json, conflicts: conflicts)
    }

    // MARK: - Parse

    /// Returns a JSON object only when the partial is a usable contribution.
    private static func parseObjectContributing(_ raw: String) -> [String: Any]? {
        let cleaned = JSONFenceStripper.strip(raw, expectedRoot: .object)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        if value is NSNull { return nil }
        return value as? [String: Any]
    }

    // MARK: - Object / value merge

    private static func mergeObjects(
        _ left: [String: Any],
        _ right: [String: Any],
        path: String,
        sourceText: String,
        scalarRanks: inout [String: FieldGrounding.MergeRank],
        conflicts: inout [MergeConflict]
    ) -> [String: Any] {
        var result = left
        for (key, rightValue) in right {
            let childPath = path.isEmpty ? key : "\(path).\(key)"
            if let leftValue = result[key] {
                result[key] = mergeValues(
                    leftValue,
                    rightValue,
                    path: childPath,
                    sourceText: sourceText,
                    scalarRanks: &scalarRanks,
                    conflicts: &conflicts
                )
            } else if !isJSONNull(rightValue) {
                result[key] = rightValue
                recordInitialScalarRank(
                    value: rightValue,
                    path: childPath,
                    sourceText: sourceText,
                    scalarRanks: &scalarRanks
                )
            } else {
                // Explicit null with no prior value: keep null so optional fields stay visible.
                result[key] = rightValue
                scalarRanks[childPath] = .ungrounded
            }
        }
        return result
    }

    private static func mergeValues(
        _ left: Any,
        _ right: Any,
        path: String,
        sourceText: String,
        scalarRanks: inout [String: FieldGrounding.MergeRank],
        conflicts: inout [MergeConflict]
    ) -> Any {
        // Null is absence: non-null always wins over null without conflict.
        if isJSONNull(left) {
            if isJSONNull(right) { return left }
            recordInitialScalarRank(
                value: right,
                path: path,
                sourceText: sourceText,
                scalarRanks: &scalarRanks
            )
            return right
        }
        if isJSONNull(right) { return left }

        if let leftObj = left as? [String: Any], let rightObj = right as? [String: Any] {
            return mergeObjects(
                leftObj,
                rightObj,
                path: path,
                sourceText: sourceText,
                scalarRanks: &scalarRanks,
                conflicts: &conflicts
            )
        }

        if let leftArr = left as? [Any], let rightArr = right as? [Any] {
            // Concat only here; full-document grounding filter runs once at the end.
            return dedupeArray(leftArr + rightArr)
        }

        // Same JSON type of scalar (or equal structures): agreement → keep left.
        if normalizedEqual(left, right) {
            return left
        }

        // Type mismatch (object/array vs scalar) or disagreeing scalars.
        let leftIsContainer = left is [String: Any] || left is [Any]
        let rightIsContainer = right is [String: Any] || right is [Any]
        if leftIsContainer || rightIsContainer {
            // Structural type clash: keep first, always record (not a grounding choice).
            recordConflict(path: path, left: left, right: right, conflicts: &conflicts)
            return left
        }

        let leftRank = scalarRanks[path] ?? .ungrounded
        let rightRank = FieldGrounding.mergeRank(forJSONValue: right, in: sourceText)

        if rightRank > leftRank {
            // Better grounded candidate wins; not a genuine conflict.
            scalarRanks[path] = rightRank
            return right
        }

        // Equal rank (including both ungrounded) or left better: first of the
        // best-ranked side wins. Record only when ranks are equal — a strictly
        // worse candidate lost cleanly on grounding.
        if rightRank == leftRank {
            recordConflict(path: path, left: left, right: right, conflicts: &conflicts)
        }
        return left
    }

    /// When a path is first filled by a non-null scalar, remember its document rank.
    private static func recordInitialScalarRank(
        value: Any,
        path: String,
        sourceText: String,
        scalarRanks: inout [String: FieldGrounding.MergeRank]
    ) {
        if value is [String: Any] || value is [Any] { return }
        scalarRanks[path] = FieldGrounding.mergeRank(forJSONValue: value, in: sourceText)
    }

    private static func recordConflict(
        path: String,
        left: Any,
        right: Any,
        conflicts: inout [MergeConflict]
    ) {
        let leftJSON = compactJSON(left)
        let rightJSON = compactJSON(right)
        if let index = conflicts.firstIndex(where: { $0.path == path }) {
            var values = conflicts[index].values
            if !values.contains(rightJSON) {
                values.append(rightJSON)
            }
            if !values.contains(leftJSON) {
                values.insert(leftJSON, at: 0)
            }
            conflicts[index] = MergeConflict(path: path, values: values)
        } else {
            var values = [leftJSON]
            if rightJSON != leftJSON {
                values.append(rightJSON)
            }
            conflicts.append(MergeConflict(path: path, values: values))
        }
    }

    // MARK: - Array filter + de-dupe

    /// Drop array entries whose non-empty string leaves are all absent from the document.
    private static func filterArrayEntries(_ value: Any, fullDocumentText: String) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValues { filterArrayEntries($0, fullDocumentText: fullDocumentText) }
        }
        if let array = value as? [Any] {
            let kept = array.compactMap { entry -> Any? in
                let filtered = filterArrayEntries(entry, fullDocumentText: fullDocumentText)
                guard FieldGrounding.isArrayEntryTextGrounded(filtered, in: fullDocumentText)
                else { return nil }
                return filtered
            }
            return dedupeArray(kept)
        }
        return value
    }

    private static func dedupeArray(_ items: [Any]) -> [Any] {
        var result: [Any] = []
        for item in items {
            let already = result.contains { normalizedEqual($0, item) }
            if !already {
                result.append(item)
            }
        }
        return result
    }

    // MARK: - Equality / normalisation

    private static func normalizedEqual(_ a: Any, _ b: Any) -> Bool {
        if isJSONNull(a), isJSONNull(b) { return true }

        if let aStr = a as? String, let bStr = b as? String {
            return normalizeString(aStr) == normalizeString(bStr)
        }

        if let aNum = a as? NSNumber, let bNum = b as? NSNumber {
            // Bool is bridged as NSNumber; keep bool/number distinct.
            if isBoolNumber(aNum) || isBoolNumber(bNum) {
                return isBoolNumber(aNum) && isBoolNumber(bNum) && aNum.boolValue == bNum.boolValue
            }
            return aNum.compare(bNum) == .orderedSame
        }

        if let aObj = a as? [String: Any], let bObj = b as? [String: Any] {
            guard aObj.count == bObj.count else { return false }
            for (key, aVal) in aObj {
                guard let bVal = bObj[key], normalizedEqual(aVal, bVal) else { return false }
            }
            return true
        }

        if let aArr = a as? [Any], let bArr = b as? [Any] {
            guard aArr.count == bArr.count else { return false }
            return zip(aArr, bArr).allSatisfy { normalizedEqual($0, $1) }
        }

        return false
    }

    private static func normalizeString(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isJSONNull(_ value: Any) -> Bool {
        value is NSNull
    }

    private static func isBoolNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: - Serialize

    private static func serializeObject(_ object: [String: Any]) -> String? {
        let sanitized = sanitizeJSONValue(object)
        guard JSONSerialization.isValidJSONObject(sanitized),
            let data = try? JSONSerialization.data(
                withJSONObject: sanitized,
                options: [.sortedKeys]
            )
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Re-box JSON numbers so a merge round-trip does not emit binary-Double noise
    /// (`99.99` → `99.98999999999999`). `JSONSerialization` parses numbers as
    /// `Double`; we re-emit via shortest-round-trip decimal text and `NSDecimalNumber`.
    private static func sanitizeJSONValue(_ value: Any) -> Any {
        if value is NSNull { return value }
        if let number = value as? NSNumber {
            if isBoolNumber(number) { return number }
            return NSDecimalNumber(string: jsonNumberString(number))
        }
        if let string = value as? String { return string }
        if let object = value as? [String: Any] {
            return object.mapValues { sanitizeJSONValue($0) }
        }
        if let array = value as? [Any] {
            return array.map { sanitizeJSONValue($0) }
        }
        return value
    }

    /// Shortest decimal form that still round-trips the Double (`%.15g` → `99.99`).
    private static func jsonNumberString(_ number: NSNumber) -> String {
        if isBoolNumber(number) {
            return number.boolValue ? "true" : "false"
        }
        let doubleValue = number.doubleValue
        if doubleValue.isNaN || doubleValue.isInfinite {
            return number.stringValue
        }
        // Integers: avoid `1.0` when the value is integral.
        if doubleValue.rounded() == doubleValue,
            doubleValue >= Double(Int64.min),
            doubleValue <= Double(Int64.max)
        {
            return String(Int64(doubleValue))
        }
        return String(format: "%.15g", doubleValue)
    }

    private static func compactJSON(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if let string = value as? String {
            // Encode as a JSON string fragment.
            if let data = try? JSONSerialization.data(
                withJSONObject: string,
                options: [.fragmentsAllowed]
            ),
                let encoded = String(data: data, encoding: .utf8)
            {
                return encoded
            }
            return "\"\(string)\""
        }
        if let number = value as? NSNumber {
            if isBoolNumber(number) {
                return number.boolValue ? "true" : "false"
            }
            return jsonNumberString(number)
        }
        if let sanitized = optionalSanitizedJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: sanitized,
                options: [.sortedKeys]
            ),
            let encoded = String(data: data, encoding: .utf8)
        {
            return encoded
        }
        return String(describing: value)
    }

    private static func optionalSanitizedJSONObject(_ value: Any) -> Any? {
        let sanitized = sanitizeJSONValue(value)
        return JSONSerialization.isValidJSONObject(sanitized) ? sanitized : nil
    }
}
