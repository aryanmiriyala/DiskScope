import Foundation
import DiskScopeCore

func registerByteFormatTests() {
    test("format: scales to readable decimal units") {
        try expectEqual(ByteFormat.string(1_500_000_000), "1.5 GB")
        try expectEqual(ByteFormat.string(512), "512 B")
        try expectEqual(ByteFormat.string(1_000_000), "1 MB")
    }

    test("format: negative values keep their sign") {
        try expect(ByteFormat.string(-2_000_000).hasPrefix("-"))
    }

    test("format: percent guards against a zero total") {
        try expectEqual(ByteFormat.percent(5, of: 0), "0%")
    }

    test("format: percent collapses tiny slivers") {
        try expectEqual(ByteFormat.percent(1, of: 1_000_000), "<1%")
    }

    test("format: relative age buckets read naturally") {
        let now = Date()
        try expectEqual(ByteFormat.relativeAge(now.addingTimeInterval(-30), now: now), "just now")
        try expectEqual(ByteFormat.relativeAge(now.addingTimeInterval(-3_600), now: now), "1 hour ago")
        try expectEqual(ByteFormat.relativeAge(now.addingTimeInterval(-172_800), now: now), "2 days ago")
        try expectEqual(ByteFormat.relativeAge(nil), "unknown")
    }
}

