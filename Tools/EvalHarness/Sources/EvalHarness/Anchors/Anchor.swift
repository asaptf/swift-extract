import Foundation

/// Named regression checks that must hold independently of aggregate metrics.
///
/// Aggregate scores can improve while the output gets worse (e.g. splitting real
/// tables into fragments raises density and column counts). Anchors catch that.
public struct AnchorFile: Codable, Sendable {
    public var anchors: [Anchor]

    public init(anchors: [Anchor]) {
        self.anchors = anchors
    }
}

public struct Anchor: Codable, Sendable, Equatable {
    /// Stable id for reporting.
    public var id: String
    /// Path relative to repo root or corpus root (see ``requiresCorpus``).
    public var path: String
    /// When true, skip with a clear message if the corpus is absent / file missing.
    public var requiresCorpus: Bool
    /// Human-readable note (optional).
    public var note: String?
    public var checks: [AnchorCheck]

    public init(
        id: String,
        path: String,
        requiresCorpus: Bool = false,
        note: String? = nil,
        checks: [AnchorCheck]
    ) {
        self.id = id
        self.path = path
        self.requiresCorpus = requiresCorpus
        self.note = note
        self.checks = checks
    }
}

public struct AnchorCheck: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// At least one detected table's cells contain all of `values` (case-insensitive).
        case tableContainsCells
        /// Exactly `count` tables detected.
        case exactTableCount
        /// At least `count` tables detected.
        case minTableCount
        /// At least one line-item-shaped table (rows≥3, cols 3–6, density≥0.80).
        case hasLineItemShapedTable
        /// Extracted seller / vendor field equals `value` (requires accuracy-style extract).
        case sellerEquals
        /// Document text contains all of `values`.
        case textContains
    }

    public var type: Kind
    public var values: [String]?
    public var value: String?
    public var count: Int?

    public init(
        type: Kind,
        values: [String]? = nil,
        value: String? = nil,
        count: Int? = nil
    ) {
        self.type = type
        self.values = values
        self.value = value
        self.count = count
    }
}

public struct AnchorResult: Sendable {
    public var id: String
    public var path: String
    public var status: Status
    public var messages: [String]

    public enum Status: String, Sendable {
        case passed
        case failed
        case skipped
    }

    public init(id: String, path: String, status: Status, messages: [String] = []) {
        self.id = id
        self.path = path
        self.status = status
        self.messages = messages
    }
}

public enum AnchorLoader {
    public static func load(from url: URL) throws -> AnchorFile {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(AnchorFile.self, from: data)
    }

    /// Bundled seed anchors shipped with the harness.
    public static func bundledAnchorsURL() -> URL? {
        Bundle.module.url(forResource: "anchors", withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "anchors", withExtension: "json")
    }
}
