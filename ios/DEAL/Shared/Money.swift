import Foundation

/// All money in the API and database is integer cents (Section 12.5).
/// These helpers are the only place cents become dollar strings and back.
enum Money {
    private static let wholeFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 0
        return f
    }()

    /// `3460000` -> `"$34,600"`; `3460050` -> `"$34,600.50"`.
    /// Pass `alwaysShowCents: true` for terminal / receipt style (`"$34,600.00"`).
    static func format(_ cents: Int, alwaysShowCents: Bool = false) -> String {
        let negative = cents < 0
        let magnitude = cents.magnitude
        let dollars = Int(magnitude / 100)
        let remainder = Int(magnitude % 100)
        let dollarString = wholeFormatter.string(from: NSNumber(value: dollars)) ?? String(dollars)
        var result = "$" + dollarString
        if alwaysShowCents || remainder != 0 {
            result += "." + (remainder < 10 ? "0\(remainder)" : "\(remainder)")
        }
        return negative ? "-" + result : result
    }

    /// Optional convenience: `nil` -> placeholder.
    static func format(_ cents: Int?, placeholder: String = "—", alwaysShowCents: Bool = false) -> String {
        guard let cents else { return placeholder }
        return format(cents, alwaysShowCents: alwaysShowCents)
    }

    /// Signed delta, e.g. `+$1,200` / `-$900`.
    static func formatDelta(_ cents: Int) -> String {
        if cents > 0 { return "+" + format(cents) }
        return format(cents)
    }

    /// Parses user-typed dollars into cents. Accepts "$34,500", "34500", "34,500.5", "34500.25".
    /// Returns nil for empty / invalid / more than two decimal places.
    static func parseDollars(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "$", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: " ", with: "")
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let wholePart = parts[0].isEmpty ? "0" : String(parts[0])
        guard wholePart.allSatisfy(\.isNumber), let whole = Int(wholePart) else { return nil }
        var fraction = 0
        if parts.count == 2 {
            let frac = String(parts[1])
            guard frac.count <= 2, frac.allSatisfy(\.isNumber) else { return nil }
            if !frac.isEmpty {
                fraction = Int(frac.count == 1 ? frac + "0" : frac) ?? 0
            }
        }
        let (mul, overflow1) = whole.multipliedReportingOverflow(by: 100)
        guard !overflow1 else { return nil }
        let (sum, overflow2) = mul.addingReportingOverflow(fraction)
        guard !overflow2 else { return nil }
        return sum
    }

    /// Cents -> plain editable dollar string for text fields ("34500" or "34500.50").
    static func editableString(_ cents: Int) -> String {
        let dollars = cents / 100
        let rem = abs(cents % 100)
        return rem == 0 ? "\(dollars)" : "\(dollars)." + (rem < 10 ? "0\(rem)" : "\(rem)")
    }
}
