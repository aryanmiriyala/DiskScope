import Foundation

/// Human-readable byte sizes.
///
/// Uses the decimal (SI) units that Finder's "Get Info" and most consumer
/// storage products use, because matching what the user sees in Finder matters
/// more than matching the physical truth of 1024-byte blocks.
public enum ByteFormat {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f
    }()

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func string(_ bytes: Int64, precise: Bool = false) -> String {
        let negative = bytes < 0
        let value = Double(abs(bytes))

        // Pick the unit from the magnitude of the value, then format within it.
        var unitIndex = 0
        var scaled = value
        while scaled >= 1000, unitIndex < units.count - 1 {
            scaled /= 1000
            unitIndex += 1
        }

        // Whole numbers get no decimal point, so "1 MB" does not render as
        // "1.0 MB". Beyond that, three significant figures reads well in a
        // table without implying precision we do not have.
        let isWholeNumber = scaled == scaled.rounded()
        let fractionDigits: Int
        if precise {
            fractionDigits = 2
        } else if isWholeNumber {
            fractionDigits = 0
        } else {
            fractionDigits = scaled >= 100 ? 0 : 1
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = fractionDigits
        f.minimumFractionDigits = fractionDigits

        let text = f.string(from: NSNumber(value: scaled)) ?? String(format: "%.1f", scaled)
        return (negative ? "-" : "") + text + " " + units[unitIndex]
    }

    /// A count without a unit, for columns where the unit is in the header.
    ///
    /// Generic over integers because the same call sites format both byte
    /// counts and file counts.
    public static func bare<T: BinaryInteger>(_ value: T) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: Int64(value))) ?? "\(value)"
    }

    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        let value = Double(part) / Double(whole) * 100
        if value < 0.1 { return "<1%" }
        return String(format: "%.0f%%", value)
    }

    /// A rough age label — "3 days ago", "2 years ago".
    public static func relativeAge(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "unknown" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "just now" }

        let minute: Double = 60
        let hour = minute * 60
        let day = hour * 24
        let month = day * 30.44
        let year = day * 365.25

        switch seconds {
        case ..<minute: return "just now"
        case ..<hour:
            let n = Int(seconds / minute)
            return "\(n) minute\(n == 1 ? "" : "s") ago"
        case ..<day:
            let n = Int(seconds / hour)
            return "\(n) hour\(n == 1 ? "" : "s") ago"
        case ..<month:
            let n = Int(seconds / day)
            return "\(n) day\(n == 1 ? "" : "s") ago"
        case ..<year:
            let n = Int(seconds / month)
            return "\(n) month\(n == 1 ? "" : "s") ago"
        default:
            let n = Int(seconds / year)
            return "\(n) year\(n == 1 ? "" : "s") ago"
        }
    }
}
