import Foundation

/// How dangerous is it to remove something in this category?
///
/// The ladder is deliberately coarse. Users act on these labels, so every
/// distinction here has to survive being read at a glance in a sidebar.
public enum RiskLevel: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Rebuilt automatically on demand. Deleting costs you time, not data.
    case regenerable = 0
    /// Safe once you have confirmed you no longer want it. May need a network
    /// fetch or a re-install to bring back.
    case disposable = 1
    /// Removing this loses something you cannot get back automatically.
    case destructive = 2
    /// App internals, caches belonging to running apps, or anything where a
    /// mistake produces confusing behaviour rather than obvious data loss.
    case caution = 3
    /// Never a deletion target. Shown for context only.
    case informational = 4

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var title: String {
        switch self {
        case .regenerable: return "Safe to clear"
        case .disposable: return "Review first"
        case .destructive: return "Data loss"
        case .caution: return "Use caution"
        case .informational: return "Read only"
        }
    }

    public var summary: String {
        switch self {
        case .regenerable:
            return "Thrown away automatically the next time you need it. Nothing is lost, you may just wait for it to rebuild."
        case .disposable:
            return "Almost certainly unwanted, but confirm you do not need it before removing. Some of this can only be recovered by downloading it again."
        case .destructive:
            return "This is your data. DiskScope will never offer to remove it automatically."
        case .caution:
            return "Belongs to a running application. Clearing it is allowed, but the app may misbehave until you restart it."
        case .informational:
            return "Reported so you understand where the space went. DiskScope does not delete this."
        }
    }

    /// Whether DiskScope will offer a cleanup action at all.
    ///
    /// Spelled out as a switch rather than `self < .informational` because the
    /// raw ordering is about *how risky deletion is*, which is not the same
    /// question as *whether to offer it*. `.destructive` sits below
    /// `.informational` in the enum but is categorically excluded: it means the
    /// user can remove it themselves if they are sure, and DiskScope will never
    /// propose it. Deriving this from the comparison silently offered exactly
    /// the data the risk model exists to protect.
    public var isDeletable: Bool {
        switch self {
        case .regenerable, .disposable, .caution:
            return true
        case .destructive, .informational:
            return false
        }
    }

    /// Whether cleanup requires the user to tick an extra confirmation box.
    public var requiresExplicitConfirmation: Bool {
        switch self {
        case .regenerable: return false
        case .disposable, .caution, .destructive, .informational: return true
        }
    }
}

/// The taxonomy of "what kind of thing is this".
///
/// Each category carries a plain-English explanation written for someone who
/// has never heard of the folder. The explanation is the product; the pie chart
/// is only a way of choosing what to read first.
public enum DiskCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    // Regenerable caches
    case applicationCaches
    case developerCaches
    case packageManagerCaches
    case browserCaches
    case systemLogs
    case crashReports
    case deviceBackups
    case simulatorData
    case xcodeArchives

    // User-adjacent data
    case messages
    case mail
    case downloads
    case trash
    case iosDeviceBackups
    case timeMachineSnapshots
    case applicationSupport
    case containerData
    case largeMedia
    case documents
    case appBundles
    case duplicateFiles

    // Accounted for, never touched
    case systemVolume
    case purgeable

    // Fallback
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .applicationCaches: return "App caches"
        case .developerCaches: return "Developer caches"
        case .packageManagerCaches: return "Package manager caches"
        case .browserCaches: return "Browser caches"
        case .systemLogs: return "Logs"
        case .crashReports: return "Crash reports"
        case .deviceBackups: return "Device backups"
        case .simulatorData: return "Simulator data"
        case .xcodeArchives: return "Xcode archives"
        case .messages: return "Messages"
        case .mail: return "Mail"
        case .downloads: return "Downloads"
        case .trash: return "Trash"
        case .iosDeviceBackups: return "iOS device backups"
        case .timeMachineSnapshots: return "Time Machine snapshots"
        case .applicationSupport: return "Application support files"
        case .containerData: return "App container data"
        case .largeMedia: return "Large media"
        case .documents: return "Documents"
        case .appBundles: return "Installed apps"
        case .duplicateFiles: return "Duplicate files"
        case .systemVolume: return "macOS system volume"
        case .purgeable: return "Purgeable space"
        case .other: return "Other"
        }
    }

    /// One or two sentences that answer "what is this and why does it exist?".
    public var explanation: String {
        switch self {
        case .applicationCaches:
            return """
            Scratch data that apps rebuild when launched — thumbnails, decoded images, \
            partially downloaded files. Growing without bound is normal; growing forever \
            is the problem.
            """
        case .developerCaches:
            return """
            Build tool caches: Xcode's DerivedData, SwiftPM artifacts, compiler module \
            caches. Deleting these costs a slow rebuild but no source code.
            """
        case .packageManagerCaches:
            return """
            Downloaded copies of dependencies kept by Homebrew, npm, Cargo, pip, CocoaPods \
            and friends. Safe to clear; the next install just re-downloads.
            """
        case .browserCaches:
            return """
            Web caches for Safari, Chrome, Firefox and Edge. Safe to clear. Anything stored \
            in cookies or local storage is a different folder and is not touched.
            """
        case .systemLogs:
            return """
            Diagnostic logs written by macOS and your apps. Useful when debugging, noise the \
            rest of the time. macOS prunes these on its own schedule, which is often too slow.
            """
        case .crashReports:
            return """
            Saved crash dumps from apps that crashed. Worth keeping until you have confirmed \
            a bug is fixed.
            """
        case .deviceBackups:
            return """
            Full backups of iPhones and iPads made by Finder or Apple Devices. Deleting one \
            means losing the only local copy of that device.
            """
        case .simulatorData:
            return """
            Installed simulator runtimes, their data, and cached build products. You can \
            delete individual devices, but deleting a runtime means re-downloading it.
            """
        case .xcodeArchives:
            return """
            Archived builds from Xcode's Organizer. Useful for reproducing old bug reports, \
            usually useless a few months later.
            """
        case .messages:
            return """
            Attachments and database files for the Messages app — images, videos, and the \
            message history itself. This is your conversation history, not a cache.
            """
        case .mail:
            return """
            Locally cached mail messages and attachments. Messages still on the server can be \
            re-downloaded, but the server copy is not guaranteed to exist anymore.
            """
        case .downloads:
            return """
            Files your browser saved. Frequently the single largest category of genuinely \
            removable junk, and the easiest to review by hand.
            """
        case .trash:
            return """
            Items you already deleted but have not emptied. Trivially removable — you have \
            already said you want them gone.
            """
        case .iosDeviceBackups:
            return """
            Backups under ~/Library/Application Support/MobileSync. Each one is a whole \
            device's worth of data, and they accumulate one per backup event.
            """
        case .timeMachineSnapshots:
            return """
            Local APFS snapshots taken by Time Machine. They are what make Time Machine able \
            to back up changes made today while you were offline. Removing them by hand can \
            break backup chains, so use tmutil instead.
            """
        case .applicationSupport:
            return """
            Where apps keep the things they consider durable: settings, databases, plugins, \
            project files. This is app state, not scratch space.
            """
        case .containerData:
            return """
            Sandboxed app data, one container per app under ~/Library/Containers. Deleting \
            a container resets that app to a fresh install.
            """
        case .largeMedia:
            return """
            Videos, images and audio large enough to matter. Usually in Movies, Pictures or \
            iCloud Drive. Your data — DiskScope will show you these, not delete them.
            """
        case .documents:
            return """
            Your actual documents. Reported for completeness so the breakdown is honest. \
            Never a deletion target.
            """
        case .appBundles:
            return """
            The applications installed on this Mac, including nested helpers like \
            browser extensions and Xcode's toolchain. Removing an app should go \
            through Finder so its support files are cleaned up too, which is why \
            DiskScope reports these rather than offering to delete them.
            """
        case .duplicateFiles:
            return """
            Byte-identical copies of the same file in two or more places, usually from \
            copying a folder instead of moving it. Removing all but one is safe as long as \
            you check nothing links to the others.
            """
        case .systemVolume:
            return """
            The read-only system volume that macOS itself lives on. It appears as a separate \
            disk in Finder and shares space with your data through APFS. You cannot delete \
            it, but understanding it explains most of the "System Data" confusion.
            """
        case .purgeable:
            return """
            Space macOS has reserved and can hand back at will. It disappears when you need \
            it, which makes disk accounting look erratic.
            """
        case .other:
            return """
            Data that does not match a category DiskScope recognises. Shown \
            honestly rather than hidden inside a catch-all bucket, and never \
            offered for automatic removal — if it were safe to delete, we would \
            know what it was.
            """
        }
    }

    /// A short "why does this folder exist at all?" note, where it is useful.
    public var originNote: String? {
        switch self {
        case .applicationCaches:
            return "Written by apps under ~/Library/Caches and by macOS under /Library/Caches."
        case .developerCaches:
            return "Mostly ~/Library/Developer, which Xcode and the Swift toolchain treat as a scratch area."
        case .timeMachineSnapshots:
            return "Not a normal folder — these are APFS snapshots of the data volume."
        case .iosDeviceBackups:
            return "Created by Finder's \"Back Up to Disk\" feature."
        default:
            return nil
        }
    }

    /// Default risk for items found in this category.
    public var defaultRisk: RiskLevel {
        switch self {
        case .applicationCaches, .packageManagerCaches, .browserCaches,
             .systemLogs, .developerCaches, .xcodeArchives:
            return .regenerable
        case .crashReports:
            return .disposable
        case .trash:
            return .disposable
        case .downloads, .simulatorData, .iosDeviceBackups, .deviceBackups:
            return .disposable
        case .duplicateFiles, .largeMedia, .messages, .mail:
            return .destructive
        case .containerData, .applicationSupport:
            return .caution
        case .documents, .appBundles:
            return .informational
        case .timeMachineSnapshots, .systemVolume, .purgeable:
            return .informational
        case .other:
            // Deliberately destructive rather than caution. For anything
            // DiskScope recognises, "caution" means the data belongs to a
            // running app and clearing it may confuse that app. For an
            // unidentified folder we have no such story: we do not know whose
            // data it is, so it must not be offered for automatic removal. If
            // grouping later identifies it, it inherits a proper risk.
            return .destructive
        }
    }

    /// Suggested order in the "start here" list — highest value first for someone
    /// who just wants their disk back.
    public var reclaimPriority: Int {
        switch self {
        case .trash: return 100
        case .xcodeArchives: return 95
        case .developerCaches: return 90
        case .packageManagerCaches: return 88
        case .browserCaches: return 85
        case .simulatorData: return 80
        case .applicationCaches: return 78
        case .systemLogs: return 70
        case .crashReports: return 65
        case .duplicateFiles: return 60
        case .downloads: return 55
        case .iosDeviceBackups: return 40
        default: return 10
        }
    }
}

/// A single line of the breakdown: a category, how big it is, and why.
public struct CategoryTotal: Sendable, Identifiable, Codable {
    public let category: DiskCategory
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let itemCount: Int
    public let risk: RiskLevel
    /// Sample paths so the user can see what got bucketed here.
    public let samplePaths: [URL]

    public var id: DiskCategory { category }

    public init(
        category: DiskCategory,
        logicalSize: Int64,
        allocatedSize: Int64,
        itemCount: Int,
        risk: RiskLevel,
        samplePaths: [URL] = []
    ) {
        self.category = category
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.itemCount = itemCount
        self.risk = risk
        self.samplePaths = samplePaths
    }

    /// Size that would actually come back, which is zero for read-only categories.
    public var reclaimableSize: Int64 { risk.isDeletable ? allocatedSize : 0 }
}
