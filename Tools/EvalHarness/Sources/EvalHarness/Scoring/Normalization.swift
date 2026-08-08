import Foundation

/// Field-level normalisation shared by accuracy scoring and pairing.
public enum FieldNormalization {
    public static func normalizeText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    public static func textsEqual(_ a: String, _ b: String) -> Bool {
        normalizeText(a) == normalizeText(b)
    }

    /// Case-insensitive substring presence (for pairing + “truth in text” gating).
    public static func textContains(_ haystack: String, needle: String) -> Bool {
        let h = normalizeText(haystack)
        let n = normalizeText(needle)
        guard !n.isEmpty else { return false }
        return h.contains(n)
    }

    public static func decimalsEqual(
        _ a: Decimal,
        _ b: Decimal,
        tolerance: Decimal = Decimal(string: "0.02")!
    ) -> Bool {
        abs(a - b) <= tolerance
    }

    public static func calendarDaysEqual(_ a: Date, _ b: Date, timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!)
        -> Bool
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let da = calendar.dateComponents([.year, .month, .day], from: a)
        let db = calendar.dateComponents([.year, .month, .day], from: b)
        return da.year == db.year && da.month == db.month && da.day == db.day
    }

    public static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func formatDecimal(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }
}
