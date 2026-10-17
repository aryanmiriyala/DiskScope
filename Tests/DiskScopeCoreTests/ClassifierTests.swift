import Foundation
import DiskScopeCore

/// Tests for the classification rule table.
///
/// The rule table is the part of DiskScope most likely to be wrong in ways
/// users notice, because a mis-classification is not a crash — it is a
/// confident, incorrect sentence about what a folder is. These tests pin the
/// ordering behaviour, since the table is "first match wins".
func registerClassifierTests() {
    let classifier = LibraryClassifier(homeDirectory: URL(fileURLWithPath: "/Users/example"))

    test("classifier: recognises the paths that fill up a dev machine") {
        try expectEqual(
            classifier.classify(path: "/Users/example/Library/Developer/Xcode/DerivedData").category,
            .developerCaches
        )
        try expectEqual(
            classifier.classify(path: "/Users/example/Library/Developer/Xcode/Archives/App-2024").category,
            .xcodeArchives
        )
        try expectEqual(
            classifier.classify(path: "/Users/example/Library/Developer/CoreSimulator/Devices/ABC-123").category,
            .simulatorData
        )
    }

    test("classifier: iOS backups are found in MobileSync, not lumped into Application Support") {
        // Application Support has a broad rule, so this only passes if the
        // specific MobileSync rule comes first. Ordering is the whole game.
        try expectEqual(
            classifier.classify(path: "/Users/example/Library/Application Support/MobileSync/Backup/abc").category,
            .iosDeviceBackups
        )
    }

    test("classifier: browser caches are distinguished from browser profiles") {
        try expectEqual(
            classifier.classify(path: "/Users/example/Library/Caches/Google/Chrome/Default/Cache").category,
            .browserCaches
        )
        // Profile data holds bookmarks and logins and must never be called a cache.
        try expectEqual(
            classifier.classify(path: "/Users/example/Library/Application Support/Google/Chrome/Default").category,
            .applicationSupport
        )
    }

    test("classifier: mail downloads are disposable, the rest of Mail is not") {
        try expectEqual(
            classifier.classify(
                path: "/Users/example/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
            ).category,
            .mail
        )
        try expectEqual(
            classifier.classify(
                path: "/Users/example/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
            ).risk,
            .disposable,
            "downloaded attachments are a much better deletion candidate than the mailbox itself"
        )
        try expectEqual(
            classifier.classify(path: "/Users/example/Library/Mail/V9").risk,
            .destructive
        )
    }

    test("classifier: Trash is disposable, Documents are never deletable") {
        try expectEqual(classifier.classify(path: "/Users/example/.Trash/old.zip").category, .trash)
        try expectEqual(classifier.classify(path: "/Users/example/.Trash/old.zip").risk, .disposable)
        try expectEqual(classifier.classify(path: "/Users/example/Documents/taxes.pdf").risk, .informational)
    }

    test("classifier: package manager caches are recognised outside Library") {
        for path in [
            "/Users/example/.cargo/registry/cache",
            "/Users/example/.npm/_cacache",
            "/Users/example/Library/Caches/Homebrew",
            "/Users/example/.gradle/caches/modules-2",
        ] {
            try expectEqual(
                classifier.classify(path: path).category,
                .packageManagerCaches,
                "expected \(path) to be a package manager cache"
            )
        }
    }

    test("classifier: unknown paths fall back rather than crashing") {
        let result = classifier.classify(path: "/Users/example/Totally/Unknown/Place")
        try expectEqual(result.category, .other)
        try expectEqual(result.risk, .caution, "unknown data should be treated cautiously")
    }

    test("classifier: user media folders are recognised as large media") {
        // `.largeMedia` existed in the taxonomy with no rule that could ever
        // produce it, so it silently never appeared in a report.
        for path in ["/Users/example/Movies", "/Users/example/Pictures", "/Users/example/Music"] {
            try expectEqual(
                classifier.classify(path: path).category,
                .largeMedia,
                "expected \(path) to be large media"
            )
        }
    }

    test("classifier: a deep path under an exact rule inherits its category") {
        // Most rules are prefix rules, which match directly. This exercises the
        // ancestor fallback, which only matters for folders whose rule is
        // anchored to one specific directory — Mail, for instance.
        let result = classifier.classify(path: "/Users/example/Library/Mail/V9/Inbox/12345.msg")
        try expectEqual(result.category, .mail)
        try expect(result.matchedRule.contains("inherited"))
    }

    test("classifier: application bundles are never a deletion target") {
        let result = classifier.classify(path: "/Applications/Safari.app")
        try expectEqual(result.category, .appBundles)
        try expect(!result.risk.isDeletable)
    }

    test("classifier: the system volume and snapshots are read-only categories") {
        for category in [DiskCategory.systemVolume, .timeMachineSnapshots, .purgeable] {
            try expect(
                !category.defaultRisk.isDeletable,
                "\(category.title) must not be offered for deletion"
            )
        }
    }

    test("classifier: every category has real explanatory copy") {
        // A category with an empty explanation would render as a blank panel,
        // which is worse than not having the category at all.
        for category in DiskCategory.allCases {
            try expect(
                category.explanation.trimmingCharacters(in: .whitespacesAndNewlines).count > 40,
                "\(category.rawValue) needs a real explanation"
            )
            try expect(!category.title.isEmpty)
        }
    }

    test("classifier: glob matching handles single wildcards") {
        try expect(LibraryClassifier.Rule.glob("*.app", matches: "Safari.app"))
        try expect(!LibraryClassifier.Rule.glob("*.app", matches: "Safari"))
        try expect(LibraryClassifier.Rule.glob("com.*.cache", matches: "com.example.cache"))
        try expect(!LibraryClassifier.Rule.glob("com.*.cache", matches: "com.example.other"))
    }
}
