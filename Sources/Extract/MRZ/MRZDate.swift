import Foundation

/// An MRZ date as both the raw `YYMMDD` field and a resolved `Date`.
public struct MRZDate: Sendable, Equatable {
    /// The six-character `YYMMDD` string as it appears in the MRZ (may contain `<`).
    public let raw: String
    /// Calendar date in UTC when `raw` is a valid day; `nil` when the field is
    /// filler-only or not a real calendar date.
    public let date: Date?

    public init(raw: String, date: Date?) {
        self.raw = raw
        self.date = date
    }
}

/// Century disambiguation and `YYMMDD` → `Date` conversion for MRZ fields.
///
/// ## Century rule
///
/// ICAO encodes only two year digits. Given a reference instant (default: now):
///
/// - **Date of birth** is *backward-looking*: the century is chosen so the
///   resulting date is on or before the reference day and within the preceding
///   100 years. Example: raw `900315` with reference 2026-07-27 → 1990-03-15
///   (not 2090-03-15).
/// - **Date of expiry** is *forward-looking*: the century is chosen so the
///   resulting date falls in the window `[referenceYear − 50, referenceYear + 50]`,
///   preferring the 2000-based interpretation when both would be valid.
///   Example: raw `301231` with reference 2026 → 2030-12-31.
///
/// Callers that need a fixed pivot (e.g. tests) pass an explicit `referenceDate`.
enum MRZDateParser {
    enum Kind {
        case birth
        case expiry
    }

    static func parse(
        _ raw: String,
        kind: Kind,
        referenceDate: Date = Date()
    ) -> MRZDate {
        guard raw.count == 6, !raw.allSatisfy({ $0 == "<" }) else {
            return MRZDate(raw: raw, date: nil)
        }

        guard let year2 = twoDigit(raw, start: 0),
            let month = twoDigit(raw, start: 2),
            let day = twoDigit(raw, start: 4),
            (1...12).contains(month),
            (1...31).contains(day)
        else {
            return MRZDate(raw: raw, date: nil)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC") ?? .current

        let refComponents = calendar.dateComponents([.year, .month, .day], from: referenceDate)
        guard let refYear = refComponents.year else {
            return MRZDate(raw: raw, date: nil)
        }

        let fullYear = resolveYear(year2, kind: kind, referenceYear: refYear)

        var components = DateComponents()
        components.year = fullYear
        components.month = month
        components.day = day
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)

        guard let candidate = calendar.date(from: components) else {
            return MRZDate(raw: raw, date: nil)
        }

        // Reject non-normalized dates (e.g. 31 Feb → March overflow).
        let back = calendar.dateComponents([.year, .month, .day], from: candidate)
        guard back.year == fullYear, back.month == month, back.day == day else {
            return MRZDate(raw: raw, date: nil)
        }

        // Birth must not land after the reference day under the chosen century.
        if kind == .birth {
            let refDay = calendar.startOfDay(for: referenceDate)
            let candDay = calendar.startOfDay(for: candidate)
            if candDay > refDay, fullYear >= 2000 {
                components.year = fullYear - 100
                if let past = calendar.date(from: components) {
                    return MRZDate(raw: raw, date: past)
                }
            }
        }

        return MRZDate(raw: raw, date: candidate)
    }

    private static func twoDigit(_ raw: String, start: Int) -> Int? {
        let chars = Array(raw)
        guard start + 1 < chars.count else { return nil }
        let high = digitValue(chars[start])
        let low = digitValue(chars[start + 1])
        guard let high, let low else { return nil }
        return high * 10 + low
    }

    private static func digitValue(_ character: Character) -> Int? {
        if character == "<" { return 0 }
        return character.wholeNumberValue
    }

    private static func resolveYear(_ year2: Int, kind: Kind, referenceYear: Int) -> Int {
        let y2000 = 2000 + year2
        let y1900 = 1900 + year2
        switch kind {
        case .birth:
            // Prefer 20xx when that year is not after the reference year.
            if y2000 <= referenceYear {
                return y2000
            }
            return y1900
        case .expiry:
            // Window centred near the present: [ref − 50, ref + 50].
            if y2000 >= referenceYear - 50 {
                return y2000
            }
            return y1900
        }
    }
}
