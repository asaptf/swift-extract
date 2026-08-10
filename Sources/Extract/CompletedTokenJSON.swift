import Foundation

/// Builds JSON snapshots that contain only **completed** tokens from a possibly
/// incomplete model stream.
///
/// ## Why half-tokens are withheld
///
/// While the model is still writing `473.00`, a naive partial parser would surface
/// `47` then `473` then `473.00`. A caller rendering that shows a wrong total —
/// and a wrong number on screen is worse than an empty field. This assembler
/// therefore surfaces a scalar only once its JSON token is provably complete:
///
/// - **strings** — after the closing unescaped quote
/// - **numbers** — after a delimiter (`,`, `}`, `]`, or whitespace)
/// - **true / false / null** — after the full keyword
/// - **objects / arrays** — nested values follow the same rules; open structures
///   are closed so the snapshot stays valid JSON
///
/// Growing collections are intentional: an array may grow element by element as
/// each element completes. Do not weaken these rules to gain a few milliseconds
/// of latency — truthfulness is the product requirement.
enum CompletedTokenJSON {
    /// Return a closed JSON document containing only completed tokens, or `nil`
    /// when no usable root object/array has started.
    ///
    /// Accepts the same leading prose / markdown fences as ``JSONFenceStripper``:
    /// the first `{` or `[` (per `expectedRoot`) starts the parse.
    static func snapshot(
        from raw: String,
        expectedRoot: ExtractionSchema.SchemaType = .object
    ) -> String? {
        let working = stripOpenFence(raw)
        let allowed: Set<Character>
        switch expectedRoot {
        case .object:
            allowed = ["{"]
        case .array:
            allowed = ["["]
        default:
            allowed = ["{", "["]
        }
        guard let start = working.firstIndex(where: { allowed.contains($0) }) else {
            return nil
        }
        var parser = Parser(text: working, index: start)
        // Root may be unclosed — completed fields still surface. Nested values
        // require a full closed structure (see parseObject/parseArray).
        guard let value = parser.parseValue(requireComplete: false) else {
            return nil
        }
        switch value.kind {
        case .object, .array:
            return value.rendered
        case .complete:
            return nil
        }
    }

    /// Drop an opening markdown fence so `{` is findable while the model is still
    /// streaming. A closed trailing fence is stripped when present.
    private static func stripOpenFence(_ raw: String) -> String {
        var text = raw
        let trimmedLeading = text.drop(while: { $0.isWhitespace || $0.isNewline })
        guard trimmedLeading.hasPrefix("```") else {
            return text
        }
        guard let newline = trimmedLeading.firstIndex(of: "\n") else {
            // Opening fence only — nothing to parse yet.
            return ""
        }
        text = String(trimmedLeading[trimmedLeading.index(after: newline)...])
        if let range = text.range(of: "```", options: .backwards) {
            let after = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            // Only strip when ``` looks like a closing fence (rest is empty or non-JSON).
            if after.isEmpty || !after.contains(where: { $0 == "{" || $0 == "[" }) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text
    }

    // MARK: - Parser

    private struct ParsedValue {
        enum Kind {
            case object
            case array
            /// A complete scalar (string / number / bool / null).
            case complete
        }
        var kind: Kind
        var rendered: String
    }

    private struct Parser {
        let text: String
        var index: String.Index

        mutating func parseValue(requireComplete: Bool) -> ParsedValue? {
            skipWhitespace()
            guard index < text.endIndex else { return nil }
            let c = text[index]
            switch c {
            case "{":
                return parseObject(requireComplete: requireComplete)
            case "[":
                return parseArray(requireComplete: requireComplete)
            case "\"":
                if let s = parseCompleteString() {
                    return ParsedValue(kind: .complete, rendered: s)
                }
                return nil
            case "-", "0"..."9":
                if let n = parseCompleteNumber() {
                    return ParsedValue(kind: .complete, rendered: n)
                }
                return nil
            case "t":
                if let lit = parseKeyword("true") {
                    return ParsedValue(kind: .complete, rendered: lit)
                }
                return nil
            case "f":
                if let lit = parseKeyword("false") {
                    return ParsedValue(kind: .complete, rendered: lit)
                }
                return nil
            case "n":
                if let lit = parseKeyword("null") {
                    return ParsedValue(kind: .complete, rendered: lit)
                }
                return nil
            default:
                return nil
            }
        }

        mutating func parseObject(requireComplete: Bool) -> ParsedValue? {
            index = text.index(after: index)
            var pairs: [(String, String)] = []
            var closed = false
            skipWhitespace()

            if index < text.endIndex, text[index] == "}" {
                index = text.index(after: index)
                return ParsedValue(kind: .object, rendered: "{}")
            }

            while index < text.endIndex {
                skipWhitespace()
                if index < text.endIndex, text[index] == "}" {
                    index = text.index(after: index)
                    closed = true
                    break
                }

                guard text[index] == "\"" else { break }
                guard let key = parseCompleteString() else { break }
                skipWhitespace()
                guard index < text.endIndex, text[index] == ":" else { break }
                index = text.index(after: index)
                skipWhitespace()
                guard index < text.endIndex else { break }

                // Nested structures must be fully closed before they surface as a
                // property value (no half-objects as array elements or fields).
                if let value = parseValue(requireComplete: true) {
                    pairs.append((key, value.rendered))
                    skipWhitespace()
                    if index < text.endIndex, text[index] == "," {
                        index = text.index(after: index)
                        continue
                    }
                    if index < text.endIndex, text[index] == "}" {
                        index = text.index(after: index)
                        closed = true
                        break
                    }
                    // Property included; further properties not yet available.
                    break
                } else {
                    // Incomplete value — omit this key.
                    break
                }
            }

            // Nested object/array-element: only surface when the closing brace was seen.
            // Root objects (requireComplete == false) may stream completed fields early.
            if requireComplete && !closed {
                return nil
            }

            let body = pairs.map { key, value in "\(key):\(value)" }.joined(separator: ",")
            return ParsedValue(kind: .object, rendered: "{\(body)}")
        }

        mutating func parseArray(requireComplete: Bool) -> ParsedValue? {
            // Arrays intentionally stream while still open: completed elements surface
            // one by one (`lineItems` grows 1 → 2 → 3). `requireComplete` applies to
            // *elements* (via parseValue below), not to the array container itself.
            _ = requireComplete
            index = text.index(after: index)
            var elements: [String] = []
            skipWhitespace()

            if index < text.endIndex, text[index] == "]" {
                index = text.index(after: index)
                return ParsedValue(kind: .array, rendered: "[]")
            }

            while index < text.endIndex {
                skipWhitespace()
                if index < text.endIndex, text[index] == "]" {
                    index = text.index(after: index)
                    break
                }
                guard index < text.endIndex else { break }

                // Elements must be complete tokens / closed structures.
                if let value = parseValue(requireComplete: true) {
                    elements.append(value.rendered)
                    skipWhitespace()
                    if index < text.endIndex, text[index] == "," {
                        index = text.index(after: index)
                        continue
                    }
                    if index < text.endIndex, text[index] == "]" {
                        index = text.index(after: index)
                        break
                    }
                    // Element included; array not yet closed — keep growing.
                    break
                } else {
                    break
                }
            }

            let body = elements.joined(separator: ",")
            return ParsedValue(kind: .array, rendered: "[\(body)]")
        }

        /// Parse a JSON string including quotes; only returns when closed.
        mutating func parseCompleteString() -> String? {
            guard index < text.endIndex, text[index] == "\"" else { return nil }
            let start = index
            index = text.index(after: index)
            var escaped = false
            while index < text.endIndex {
                let c = text[index]
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    index = text.index(after: index)
                    return String(text[start..<index])
                }
                index = text.index(after: index)
            }
            return nil
        }

        /// Parse a number only when a delimiter proves it is finished.
        ///
        /// End-of-buffer is **not** enough — the next stream piece might continue
        /// the number (`473` + `.00`).
        mutating func parseCompleteNumber() -> String? {
            let start = index
            if text[index] == "-" {
                index = text.index(after: index)
                guard index < text.endIndex, text[index].isJSONDigit else {
                    index = start
                    return nil
                }
            }
            guard index < text.endIndex else {
                index = start
                return nil
            }

            if text[index] == "0" {
                index = text.index(after: index)
            } else if text[index].isJSONDigit {
                while index < text.endIndex, text[index].isJSONDigit {
                    index = text.index(after: index)
                }
            } else {
                index = start
                return nil
            }

            if index < text.endIndex, text[index] == "." {
                let afterDot = text.index(after: index)
                guard afterDot < text.endIndex, text[afterDot].isJSONDigit else {
                    // `473.` is not a complete number yet.
                    index = start
                    return nil
                }
                index = afterDot
                while index < text.endIndex, text[index].isJSONDigit {
                    index = text.index(after: index)
                }
            }

            if index < text.endIndex, text[index] == "e" || text[index] == "E" {
                index = text.index(after: index)
                if index < text.endIndex, text[index] == "+" || text[index] == "-" {
                    index = text.index(after: index)
                }
                guard index < text.endIndex, text[index].isJSONDigit else {
                    index = start
                    return nil
                }
                while index < text.endIndex, text[index].isJSONDigit {
                    index = text.index(after: index)
                }
            }

            guard index < text.endIndex else {
                index = start
                return nil
            }
            let next = text[index]
            guard isNumberDelimiter(next) else {
                index = start
                return nil
            }
            // Do not consume the delimiter — object/array parsers need it.
            return String(text[start..<index])
        }

        mutating func parseKeyword(_ word: String) -> String? {
            let start = index
            for ch in word {
                guard index < text.endIndex, text[index] == ch else {
                    index = start
                    return nil
                }
                index = text.index(after: index)
            }
            // Keyword complete when fully matched; cannot grow further. A following
            // alphanumeric would be invalid JSON — treat as incomplete.
            if index < text.endIndex {
                let next = text[index]
                if next.isLetter || next.isJSONDigit || next == "_" {
                    index = start
                    return nil
                }
            }
            return word
        }

        mutating func skipWhitespace() {
            while index < text.endIndex, text[index].isJSONWhitespace {
                index = text.index(after: index)
            }
        }

        private func isNumberDelimiter(_ c: Character) -> Bool {
            c == "," || c == "}" || c == "]" || c.isJSONWhitespace
        }
    }
}

// MARK: - Character helpers

extension Character {
    fileprivate var isJSONDigit: Bool {
        self >= "0" && self <= "9"
    }

    fileprivate var isJSONWhitespace: Bool {
        self == " " || self == "\t" || self == "\n" || self == "\r"
    }
}
