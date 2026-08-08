import CoreGraphics
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

/// Where an extracted leaf was located on the source page or image.
///
/// Present only when the value was found in positioned geometry (PDF text layer or
/// Vision OCR). ``FieldSignal/provenance`` is `nil` for ``Grounding/reformatted`` and
/// ``Grounding/absent`` leaves, for plain-text sources without boxes, and whenever a
/// textual match cannot be localised to a rectangle — never a guessed box.
///
/// ## Coordinate convention
///
/// Both PDF text-layer ingestion and Vision OCR convert into **one** space:
///
/// | Property | Convention |
/// | --- | --- |
/// | Origin | **Top-left** of the page (PDF media box) or image |
/// | X axis | Increases to the **right** |
/// | Y axis | Increases **downward** |
/// | Units | **Normalised** to the page/image size: `x`, `y`, `width`, `height` ∈ `[0, 1]` |
/// | Page | ``pageIndex`` is **0-based**; each provenance refers to a **single** page |
///
/// PDFKit’s native character bounds use a bottom-left origin in points; the PDF adapter
/// flips and normalises them. Vision’s `boundingBox` is bottom-left normalised; the OCR
/// adapter flips Y the same way. Callers can map a box to pixels as
/// `(x * W, y * H, width * W, height * H)` with a top-left image origin.
///
/// ## Multi-block and multi-page values
///
/// A value that spans several blocks on the **same** page (multi-word PDF fragments,
/// multi-line address lines) resolves to the **axis-aligned union** of those blocks’
/// boxes on that page.
///
/// When a value spans **pages**, a single `CGRect` cannot represent the full extent.
/// Provenance then uses the **lowest ``pageIndex``** that contributes matching blocks
/// and unions **only that page’s** boxes; later pages are omitted rather than guessed.
/// Prefer table-cell geometry when the value matches a reconstructed cell — cell rects
/// are tighter than the enclosing text blocks.
public struct FieldProvenance: Sendable, Equatable {
    /// Zero-based page index (images are page `0`).
    public let pageIndex: Int
    /// Normalised top-left bounding box (see type docs).
    public let boundingBox: CGRect

    public init(pageIndex: Int, boundingBox: CGRect) {
        self.pageIndex = pageIndex
        self.boundingBox = boundingBox
    }
}

/// Grounding evidence for one leaf field of an extraction result.
///
/// One row carries both **whether** the value was found (``grounding``) and **where**
/// (``provenance``). Callers must not zip two parallel lists by index.
public struct FieldSignal: Sendable, Equatable {
    /// Dotted / indexed path, e.g. `total`, `items[0].name`.
    public let path: String
    /// How this leaf relates to the source document text.
    public let grounding: Grounding
    /// Page + box when the value was localised in positioned geometry; otherwise `nil`.
    ///
    /// Always `nil` for ``Grounding/reformatted`` and ``Grounding/absent``. Also `nil`
    /// when the source has no boxes or the match could not be tied to a rectangle.
    public let provenance: FieldProvenance?

    public init(path: String, grounding: Grounding, provenance: FieldProvenance? = nil) {
        self.path = path
        self.grounding = grounding
        self.provenance = provenance
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

    /// Positioned fragment used for provenance location.
    private struct PositionedFragment {
        let text: String
        let pageIndex: Int
        let box: CGRect
        /// True when this fragment is a reconstructed table cell (preferred over blocks).
        let isTableCell: Bool
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
        /// Table cells first, then blocks, for location. Empty when no geometry.
        let fragments: [PositionedFragment]
        /// Blocks (non-cell) grouped by page in reading order for multi-block unions.
        let blocksByPage: [Int: [PositionedFragment]]

        init(
            sourceText: String,
            stats: ComputeStats?,
            blocks: [ExtractedDocument.Block],
            tables: [ExtractedTable]
        ) {
            raw = sourceText
            self.stats = stats
            normalized = FieldGrounding.normalizeForSearch(sourceText, stats: stats)
            numericSkeleton = FieldGrounding.numericSkeleton(sourceText, stats: stats)

            var cells: [PositionedFragment] = []
            for table in tables {
                for cell in table.cells {
                    guard let box = cell.boundingBox else { continue }
                    let text = cell.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    cells.append(
                        PositionedFragment(
                            text: text,
                            pageIndex: table.pageIndex,
                            box: box,
                            isTableCell: true
                        )
                    )
                }
            }

            var blockFragments: [PositionedFragment] = []
            for block in blocks {
                guard let box = block.boundingBox, let page = block.pageIndex else { continue }
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                blockFragments.append(
                    PositionedFragment(
                        text: text,
                        pageIndex: page,
                        box: box,
                        isTableCell: false
                    )
                )
            }

            // Prefer cells when locating: they appear first in `fragments`.
            fragments = cells + blockFragments
            blocksByPage = Dictionary(grouping: blockFragments, by: \.pageIndex).mapValues {
                FieldGrounding.sortedReadingOrder($0)
            }
        }

        var hasGeometry: Bool { !fragments.isEmpty }
    }

    private struct LeafOutcome {
        let grounding: Grounding
        let provenance: FieldProvenance?
    }

    /// Compute per-leaf grounding of `value` against `sourceText`.
    static func compute<T: Extractable>(
        value: T,
        sourceText: String,
        attempts: Int,
        chunksUsed: Int
    ) -> ExtractionSignals {
        compute(
            value: value,
            sourceText: sourceText,
            attempts: attempts,
            chunksUsed: chunksUsed,
            blocks: [],
            tables: [],
            stats: nil
        )
    }

    /// Compute grounding with optional positioned geometry for provenance.
    static func compute<T: Extractable>(
        value: T,
        sourceText: String,
        attempts: Int,
        chunksUsed: Int,
        blocks: [ExtractedDocument.Block],
        tables: [ExtractedTable]
    ) -> ExtractionSignals {
        compute(
            value: value,
            sourceText: sourceText,
            attempts: attempts,
            chunksUsed: chunksUsed,
            blocks: blocks,
            tables: tables,
            stats: nil
        )
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
        compute(
            value: value,
            sourceText: sourceText,
            attempts: attempts,
            chunksUsed: chunksUsed,
            blocks: [],
            tables: [],
            stats: stats
        )
    }

    /// Full compute entry used by ``Extract`` and tests.
    static func compute<T: Extractable>(
        value: T,
        sourceText: String,
        attempts: Int,
        chunksUsed: Int,
        blocks: [ExtractedDocument.Block],
        tables: [ExtractedTable],
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

        let source = SourceIndex(
            sourceText: sourceText,
            stats: stats,
            blocks: blocks,
            tables: tables
        )
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
                    fields.append(FieldSignal(path: childPath, grounding: .reformatted, provenance: nil))
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
                    fields.append(FieldSignal(path: childPath, grounding: .reformatted, provenance: nil))
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
                let outcome = dateGrounding(json: json, source: source)
                fields.append(
                    FieldSignal(path: path, grounding: outcome.grounding, provenance: outcome.provenance)
                )
            } else if let string = json as? String {
                let outcome = stringGrounding(string, source: source)
                fields.append(
                    FieldSignal(path: path, grounding: outcome.grounding, provenance: outcome.provenance)
                )
            } else {
                // Encoded non-string for a string schema (unusual) — treat as reformatted.
                fields.append(FieldSignal(path: path, grounding: .reformatted, provenance: nil))
            }

        case .number, .integer:
            let outcome = numberGrounding(json: json, source: source)
            fields.append(
                FieldSignal(path: path, grounding: outcome.grounding, provenance: outcome.provenance)
            )

        case .boolean:
            // Booleans are not groundable against free text; report reformatted.
            fields.append(FieldSignal(path: path, grounding: .reformatted, provenance: nil))

        case .null:
            // Explicit null is not groundable; report reformatted.
            fields.append(FieldSignal(path: path, grounding: .reformatted, provenance: nil))
        }
    }

    // MARK: Leaf grounding

    private static func stringGrounding(_ value: String, source: SourceIndex) -> LeafOutcome {
        if value.isEmpty {
            // Empty string has no informative substring; treat as absent.
            return LeafOutcome(grounding: .absent, provenance: nil)
        }
        if source.raw.contains(value) {
            let provenance = locate(
                value: value,
                mode: .verbatim,
                source: source
            )
            return LeafOutcome(grounding: .verbatim, provenance: provenance)
        }
        let normalizedValue = normalizeForSearch(value, stats: source.stats)
        if !normalizedValue.isEmpty, source.normalized.contains(normalizedValue) {
            let provenance = locate(
                value: value,
                mode: .normalized,
                source: source
            )
            return LeafOutcome(grounding: .normalized, provenance: provenance)
        }
        return LeafOutcome(grounding: .absent, provenance: nil)
    }

    private static func dateGrounding(json: Any, source: SourceIndex) -> LeafOutcome {
        // Prefer string encodings produced by our custom date encoder.
        if let string = json as? String {
            if source.raw.contains(string) {
                return LeafOutcome(
                    grounding: .verbatim,
                    provenance: locate(value: string, mode: .verbatim, source: source)
                )
            }
            // Also try date-only prefix of an ISO timestamp.
            if string.count >= 10 {
                let prefix = String(string.prefix(10))
                if prefix.contains("-"), source.raw.contains(prefix) {
                    return LeafOutcome(
                        grounding: .verbatim,
                        provenance: locate(value: prefix, mode: .verbatim, source: source)
                    )
                }
            }
            let normalized = normalizeForSearch(string, stats: source.stats)
            if !normalized.isEmpty, source.normalized.contains(normalized) {
                return LeafOutcome(
                    grounding: .normalized,
                    provenance: locate(value: string, mode: .normalized, source: source)
                )
            }
        } else if let number = json as? NSNumber {
            let string = number.stringValue
            if source.raw.contains(string) {
                return LeafOutcome(
                    grounding: .verbatim,
                    provenance: locate(value: string, mode: .verbatim, source: source)
                )
            }
        }
        // Schema-declared date-time: model reformats human dates → ISO. Not absent.
        return LeafOutcome(grounding: .reformatted, provenance: nil)
    }

    private static func numberGrounding(json: Any, source: SourceIndex) -> LeafOutcome {
        let candidates = numberSearchCandidates(json)
        for candidate in candidates where !candidate.isEmpty {
            // Sign-aware: positive `12.5` must not ground as `.verbatim` against
            // source `Refund: -12.50` just because the digits sit inside the
            // signed occurrence.
            if containsNumericCandidate(source.raw, candidate: candidate) {
                return LeafOutcome(
                    grounding: .verbatim,
                    provenance: locateNumeric(candidate: candidate, mode: .verbatim, source: source)
                )
            }
        }
        // Currency / grouping variants: compare digit+separator runs (signs kept).
        // Same sign boundary rule as raw: unsigned skeleton `12.5` must not hit
        // inside source skeleton `-12.50`.
        for candidate in candidates {
            let skeleton = numericSkeleton(candidate, stats: source.stats)
            if !skeleton.isEmpty,
                containsNumericCandidate(source.numericSkeleton, candidate: skeleton)
            {
                return LeafOutcome(
                    grounding: .normalized,
                    provenance: locateNumeric(candidate: candidate, mode: .normalized, source: source)
                )
            }
        }
        // Unmatched numbers are reformatted, never absent. Small integers would match
        // spuriously across free text if we flagged missing digits as absent, so a
        // fabricated number is intentionally never reported as absent. See Grounding docs.
        return LeafOutcome(grounding: .reformatted, provenance: nil)
    }

    // MARK: Provenance location

    private enum LocateMode {
        case verbatim
        case normalized
    }

    /// Locate `value` in positioned geometry. Prefers table cells, then single blocks,
    /// then multi-block unions (same page). Cross-page matches report the first page only.
    private static func locate(
        value: String,
        mode: LocateMode,
        source: SourceIndex
    ) -> FieldProvenance? {
        guard source.hasGeometry, !value.isEmpty else { return nil }

        // 1. Table cells (exact equality preferred — tighter rect than blocks).
        if let cell = bestCellMatch(value: value, mode: mode, fragments: source.fragments) {
            return FieldProvenance(pageIndex: cell.pageIndex, boundingBox: cell.box)
        }

        // 2. Single block contains the value.
        if let block = bestSingleBlockMatch(value: value, mode: mode, source: source) {
            return FieldProvenance(pageIndex: block.pageIndex, boundingBox: block.box)
        }

        // 3. Multi-block window on each page (reading order); first page wins.
        if let multi = multiBlockMatch(value: value, mode: mode, source: source) {
            return multi
        }

        // 4. Cross-page span: union only the first page's contributing boxes.
        return crossPageMatch(value: value, mode: mode, source: source)
    }

    private static func locateNumeric(
        candidate: String,
        mode: LocateMode,
        source: SourceIndex
    ) -> FieldProvenance? {
        // Prefer raw candidate location; for normalized also try digit skeleton forms.
        if let found = locate(value: candidate, mode: mode, source: source) {
            return found
        }
        if mode == .normalized {
            // Currency in source often looks like "$12.50" while candidate is "12.5".
            // Block text may still contain the digits; try normalized locate with
            // skeleton-friendly variants already covered by multi-block contains.
            let skeleton = numericSkeleton(candidate, stats: source.stats)
            if !skeleton.isEmpty, skeleton != candidate {
                return locate(value: skeleton, mode: .normalized, source: source)
            }
        }
        return nil
    }

    private static func bestCellMatch(
        value: String,
        mode: LocateMode,
        fragments: [PositionedFragment]
    ) -> PositionedFragment? {
        let cells = fragments.filter(\.isTableCell)
        // Exact equality first.
        for cell in cells {
            if textMatches(cell.text, value: value, mode: mode, requireFullEquality: true) {
                return cell
            }
        }
        // Then cell text contains value (or value contains cell for short cells).
        for cell in cells {
            if textMatches(cell.text, value: value, mode: mode, requireFullEquality: false) {
                return cell
            }
        }
        return nil
    }

    private static func bestSingleBlockMatch(
        value: String,
        mode: LocateMode,
        source: SourceIndex
    ) -> PositionedFragment? {
        let blocks = source.fragments.filter { !$0.isTableCell }
        // Prefer the smallest box among matches (tightest highlight).
        var best: PositionedFragment?
        var bestArea = CGFloat.greatestFiniteMagnitude
        for block in blocks {
            guard textMatches(block.text, value: value, mode: mode, requireFullEquality: false)
            else { continue }
            let area = block.box.width * block.box.height
            if area < bestArea {
                bestArea = area
                best = block
            }
        }
        return best
    }

    private static func multiBlockMatch(
        value: String,
        mode: LocateMode,
        source: SourceIndex
    ) -> FieldProvenance? {
        let pages = source.blocksByPage.keys.sorted()
        for page in pages {
            guard let blocks = source.blocksByPage[page], blocks.count >= 2 else { continue }
            if let box = smallestMatchingWindow(blocks: blocks, value: value, mode: mode) {
                return FieldProvenance(pageIndex: page, boundingBox: box)
            }
        }
        return nil
    }

    private static func crossPageMatch(
        value: String,
        mode: LocateMode,
        source: SourceIndex
    ) -> FieldProvenance? {
        let pages = source.blocksByPage.keys.sorted()
        guard pages.count >= 2 else { return nil }

        // Flatten in page order; each fragment remembers its page.
        var ordered: [PositionedFragment] = []
        for page in pages {
            ordered.append(contentsOf: source.blocksByPage[page] ?? [])
        }
        guard ordered.count >= 2 else { return nil }

        // Find the smallest window whose joined text matches; report first page only.
        let n = ordered.count
        var bestStart: Int?
        var bestEnd: Int?
        var bestSpan = Int.max

        for start in 0..<n {
            var joined = ""
            for end in start..<n {
                if end > start { joined += " " }
                joined += ordered[end].text
                if textMatches(joined, value: value, mode: mode, requireFullEquality: false) {
                    let span = end - start
                    if span < bestSpan {
                        bestSpan = span
                        bestStart = start
                        bestEnd = end
                    }
                    break  // smallest end for this start
                }
                let maxLen = max(value.count * 4, value.count + 80)
                if joined.count > maxLen { break }
            }
        }

        guard let start = bestStart, let end = bestEnd else { return nil }
        let window = Array(ordered[start...end])
        let firstPage = window.map(\.pageIndex).min() ?? window[0].pageIndex
        let pageBoxes = window.filter { $0.pageIndex == firstPage }.map(\.box)
        guard let first = pageBoxes.first else { return nil }
        let union = pageBoxes.dropFirst().reduce(first) { $0.union($1) }
        return FieldProvenance(pageIndex: firstPage, boundingBox: union)
    }

    /// Smallest consecutive reading-order window on one page whose joined text matches.
    private static func smallestMatchingWindow(
        blocks: [PositionedFragment],
        value: String,
        mode: LocateMode
    ) -> CGRect? {
        let n = blocks.count
        var bestBox: CGRect?
        var bestSpan = Int.max

        for start in 0..<n {
            var joined = ""
            var union: CGRect?
            for end in start..<n {
                if end > start { joined += " " }
                joined += blocks[end].text
                union = union.map { $0.union(blocks[end].box) } ?? blocks[end].box

                if textMatches(joined, value: value, mode: mode, requireFullEquality: false) {
                    let span = end - start
                    if span < bestSpan, let union {
                        bestSpan = span
                        bestBox = union
                    }
                    break
                }

                let maxLen = max(value.count * 4, value.count + 80)
                if joined.count > maxLen { break }
            }
        }
        return bestBox
    }

    private static func textMatches(
        _ haystack: String,
        value: String,
        mode: LocateMode,
        requireFullEquality: Bool
    ) -> Bool {
        switch mode {
        case .verbatim:
            if requireFullEquality {
                return haystack == value
            }
            return haystack.contains(value)
        case .normalized:
            let nh = normalizeForSearch(haystack, stats: nil)
            let nv = normalizeForSearch(value, stats: nil)
            guard !nh.isEmpty, !nv.isEmpty else { return false }
            if requireFullEquality {
                return nh == nv
            }
            return nh.contains(nv)
        }
    }

    private static func sortedReadingOrder(_ fragments: [PositionedFragment]) -> [PositionedFragment] {
        fragments.sorted { a, b in
            if !sameReadingLine(a.box, b.box) {
                return a.box.minY < b.box.minY
            }
            return a.box.minX < b.box.minX
        }
    }

    private static func sameReadingLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let minH = min(a.height, b.height)
        if minH > 0, overlap / minH >= 0.25 {
            return true
        }
        let tol = max(max(a.height, b.height) * 0.6, 0.008)
        return abs(a.midY - b.midY) <= tol
    }

    /// Substring match that respects numeric sign boundaries.
    ///
    /// An unsigned candidate must not match when the occurrence is immediately
    /// preceded by a minus (Unicode-aware). A signed candidate already includes
    /// its leading minus in the search string, so a hit is polarity-correct.
    private static func containsNumericCandidate(_ source: String, candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        let candidateSigned = candidateHasLeadingMinus(candidate)
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
            let range = source.range(of: candidate, range: searchStart..<source.endIndex)
        {
            if !candidateSigned, range.lowerBound > source.startIndex {
                let before = source[source.index(before: range.lowerBound)]
                if before.unicodeScalars.count == 1,
                    let scalar = before.unicodeScalars.first,
                    isMinusScalar(scalar)
                {
                    searchStart = range.upperBound
                    continue
                }
            }
            return true
        }
        return false
    }

    private static func candidateHasLeadingMinus(_ candidate: String) -> Bool {
        guard let first = candidate.unicodeScalars.first else { return false }
        return isMinusScalar(first)
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
