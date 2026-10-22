// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Aryan Miriyala
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Human-readable byte sizes.
///
/// Uses the decimal (SI) units that Finder's "Get Info" and most consumer
/// storage products use, because matching what the user sees in Finder matters
/// more than matching the physical truth of 1024-byte blocks.
public enum ByteFormat {
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

    /// Parse a byte count written the way a person would write it.
    ///
    /// Accepts a plain number of bytes, or a number with a unit: `500`,
    /// `500B`, `5MB`, `1.5 GB`, `2GiB`. The decimal units match what
    /// `string(_:)` prints, so the tool's own output can be fed back into it.
    /// The binary units are accepted too, because they are what a person
    /// reading a `stat` or a `df -h` will reach for.
    ///
    /// Returns nil for anything it does not understand. Callers are expected
    /// to say so rather than fall back to a default: a size flag that quietly
    /// ignores what was asked for is worse than one that refuses.
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        // Split the number from the unit. The number may hold a decimal
        // point, so the split is on the first character that is not one.
        var digits = ""
        var unit = ""
        for character in trimmed {
            if character.isNumber || character == "." {
                if !unit.isEmpty { return nil }   // digits after the unit
                digits.append(character)
            } else if character.isWhitespace {
                continue
            } else {
                unit.append(character)
            }
        }

        guard let amount = Double(digits) else { return nil }

        let multiplier: Double
        switch unit {
        case "", "b":
            multiplier = 1
        case "k", "kb":
            multiplier = 1_000
        case "m", "mb":
            multiplier = 1_000_000
        case "g", "gb":
            multiplier = 1_000_000_000
        case "t", "tb":
            multiplier = 1_000_000_000_000
        case "kib":
            multiplier = 1_024
        case "mib":
            multiplier = 1_048_576
        case "gib":
            multiplier = 1_073_741_824
        case "tib":
            multiplier = 1_099_511_627_776
        default:
            return nil
        }

        let bytes = amount * multiplier
        guard bytes >= 0, bytes <= Double(Int64.max) else { return nil }
        return Int64(bytes)
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
