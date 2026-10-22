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

    test("parse: a plain number is a number of bytes") {
        try expectEqual(ByteFormat.parse("500"), 500)
        try expectEqual(ByteFormat.parse("1048576"), 1_048_576)
        try expectEqual(ByteFormat.parse("  500  "), 500)
    }

    test("parse: decimal units match the units the formatter prints") {
        try expectEqual(ByteFormat.parse("1KB"), 1_000)
        try expectEqual(ByteFormat.parse("5MB"), 5_000_000)
        try expectEqual(ByteFormat.parse("1.5GB"), 1_500_000_000)
        try expectEqual(ByteFormat.parse("2 tb"), 2_000_000_000_000)
    }

    test("parse: binary units are understood too") {
        try expectEqual(ByteFormat.parse("1KiB"), 1_024)
        try expectEqual(ByteFormat.parse("1MiB"), 1_048_576)
        try expectEqual(ByteFormat.parse("1GiB"), 1_073_741_824)
    }

    test("parse: what cannot be read is rejected rather than guessed at") {
        try expectEqual(ByteFormat.parse("banana"), nil)
        try expectEqual(ByteFormat.parse(""), nil)
        try expectEqual(ByteFormat.parse("12 apples"), nil)
        try expectEqual(ByteFormat.parse("MB"), nil)
        try expectEqual(ByteFormat.parse("-5"), nil)
    }

    test("parse: the formatter's own output can be read back") {
        for bytes in [Int64(1), 512, 1_500, 1_000_000, 2_500_000_000] {
            let text = ByteFormat.string(bytes)
            let parsed = ByteFormat.parse(text)
            try expect(parsed != nil, "could not read back \"\(text)\"")
            // The formatter rounds to one decimal place, so the round trip is
            // close rather than exact.
            let difference = abs((parsed ?? 0) - bytes)
            try expectLessThan(difference, bytes / 10 + 1)
        }
    }
}

