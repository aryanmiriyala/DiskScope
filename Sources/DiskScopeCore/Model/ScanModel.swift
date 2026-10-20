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

/// The kind of filesystem entry a scan encountered.
public enum EntryKind: String, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
}

/// A directory aggregated during a scan.
///
/// The scanner deliberately does *not* materialize one node per file. A typical
/// user home directory holds millions of files, and keeping them all resident is
/// how naive analyzers become slow and memory-hungry. Instead we keep one
/// aggregate per *directory* (a few hundred thousand at most) and stream
/// interesting individual files — large ones, duplicates, denied paths — into
/// dedicated side tables.
public struct DirectoryRecord: Sendable, Identifiable, Codable {
    public let url: URL
    public var name: String
    public var kind: EntryKind

    /// Logical bytes contributed by *this* directory entry only.
    public var ownLogicalSize: Int64
    /// Physical bytes (`st_blocks * 512`) contributed by this directory entry only.
    public var ownAllocatedSize: Int64

    /// Logical bytes of the whole subtree, with hard links counted once.
    public var subtreeLogicalSize: Int64
    /// Physical bytes of the whole subtree.
    public var subtreeAllocatedSize: Int64

    /// Files sitting *directly* in this directory.
    ///
    /// Needed because `fileCount` is a subtree total: summing `fileCount` over
    /// every directory counts each file once per ancestor, which inflated the
    /// reported total by roughly seven times. `ownFileCount` is the only field
    /// that can be summed without double counting.
    public var ownFileCount: Int

    /// Number of files in this subtree (not including subdirectories).
    public var fileCount: Int
    /// Number of directories in this subtree, including this one.
    public var directoryCount: Int
    /// Number of symbolic links in this subtree. Tracked separately because a
    /// link is not a file and contributes no meaningful bytes.
    public var symlinkCount: Int

    /// Newest modification date observed in this subtree.
    public var newestModification: Date?

    public var id: URL { url }

    public init(
        url: URL,
        name: String,
        kind: EntryKind = .directory,
        ownLogicalSize: Int64 = 0,
        ownAllocatedSize: Int64 = 0,
        subtreeLogicalSize: Int64 = 0,
        subtreeAllocatedSize: Int64 = 0,
        fileCount: Int = 0,
        directoryCount: Int = 1,
        symlinkCount: Int = 0,
        ownFileCount: Int = 0,
        newestModification: Date? = nil
    ) {
        self.url = url
        self.name = name
        self.kind = kind
        self.ownLogicalSize = ownLogicalSize
        self.ownAllocatedSize = ownAllocatedSize
        self.subtreeLogicalSize = subtreeLogicalSize
        self.subtreeAllocatedSize = subtreeAllocatedSize
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.symlinkCount = symlinkCount
        self.ownFileCount = ownFileCount
        self.newestModification = newestModification
    }

    /// Largest modification date of the two, used when merging children upward.
    public mutating func mergeModification(_ date: Date?) {
        guard let date else { return }
        if newestModification == nil || date > newestModification! {
            newestModification = date
        }
    }
}

/// A file large enough to be worth surfacing individually.
public struct LargeFileRecord: Sendable, Identifiable, Codable {
    public let url: URL
    public var logicalSize: Int64
    public var allocatedSize: Int64
    public var modificationDate: Date?
    public var isHardLinked: Bool

    public var id: URL { url }

    public init(
        url: URL,
        logicalSize: Int64,
        allocatedSize: Int64,
        modificationDate: Date?,
        isHardLinked: Bool
    ) {
        self.url = url
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.modificationDate = modificationDate
        self.isHardLinked = isHardLinked
    }
}

/// A path we could not read, and why.
///
/// This is load-bearing for trust. An analyzer that silently reports "0 bytes"
/// for a directory it was not allowed to open looks identical to an analyzer
/// that found an empty directory. DiskScope records every denial so the UI can
/// say "12 directories unreadable — grant Full Disk Access" instead of lying.
public struct DeniedPathRecord: Sendable, Identifiable, Codable, Hashable {
    public enum Reason: String, Sendable, Codable {
        case permissionDenied
        case notFound
        case tooManyLevelsOfSymbolicLinks
        case unreadable
        case timedOut

        public var explanation: String {
            switch self {
            case .permissionDenied:
                return "macOS denied access to this location."
            case .notFound:
                return "The item disappeared while scanning, which usually means another process changed it."
            case .tooManyLevelsOfSymbolicLinks:
                return "A symbolic link chain looped back on itself. The link was skipped."
            case .unreadable:
                return "The item exists but could not be decoded or read."
            case .timedOut:
                return "The filesystem took too long to respond. Scanning this branch was abandoned."
            }
        }
    }

    public let url: URL
    public let reason: Reason

    public var id: String { url.path + (reason.rawValue) }

    public init(url: URL, reason: Reason) {
        self.url = url
        self.reason = reason
    }
}

/// A mounted filesystem that was deliberately not walked.
///
/// Recording these matters for honesty: "78 GB" and "78 GB plus 200 GB on an
/// external drive you did not ask about" are different claims, and a report
/// that silently omits the second looks like it examined everything.
public struct SkippedMount: Sendable, Identifiable, Codable {
    /// Where the other filesystem is mounted.
    public let url: URL
    /// The device identifier the mount belongs to, for the report to show.
    public let device: UInt64

    public var id: URL { url }

    public init(url: URL, device: UInt64) {
        self.url = url
        self.device = device
    }
}

/// The result of walking one root.
///
/// A scan is always scoped to a set of explicit roots so that the user (and the
/// app) never touch anything they did not ask about.
public struct ScanResult: Sendable {
    public var roots: [URL]
    public var directories: [DirectoryRecord]
    public var largeFiles: [LargeFileRecord]
    public var deniedPaths: [DeniedPathRecord]
    /// Mounted filesystems left unwalked because they sit on another device.
    public var skippedMounts: [SkippedMount]

    /// Filesystem-reported totals keyed by volume identifier, used to sanity-check
    /// our own arithmetic against what APFS claims.
    public var volumeTotals: [VolumeUsage]

    public var startedAt: Date
    public var finishedAt: Date
    public var elapsed: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    /// Hard links whose bytes were counted once and not again.
    public var deduplicatedHardLinks: Int

    /// Logical and physical bytes observed across all roots.
    public var scannedLogicalSize: Int64
    public var scannedAllocatedSize: Int64

    public init(
        roots: [URL],
        directories: [DirectoryRecord] = [],
        largeFiles: [LargeFileRecord] = [],
        deniedPaths: [DeniedPathRecord] = [],
        skippedMounts: [SkippedMount] = [],
        volumeTotals: [VolumeUsage] = [],
        startedAt: Date = .now,
        finishedAt: Date = .now,
        deduplicatedHardLinks: Int = 0,
        scannedLogicalSize: Int64 = 0,
        scannedAllocatedSize: Int64 = 0
    ) {
        self.roots = roots
        self.directories = directories
        self.largeFiles = largeFiles
        self.deniedPaths = deniedPaths
        self.skippedMounts = skippedMounts
        self.volumeTotals = volumeTotals
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.deduplicatedHardLinks = deduplicatedHardLinks
        self.scannedLogicalSize = scannedLogicalSize
        self.scannedAllocatedSize = scannedAllocatedSize
    }

    /// Total files observed across the scan.
    ///
    /// Sums `ownFileCount`, never `fileCount`. `fileCount` is a subtree total,
    /// so summing it over every directory would count each file once for the
    /// directory holding it and again for every ancestor.
    public var fileCount: Int {
        directories.reduce(0) { $0 + $1.ownFileCount }
    }

    /// Total directories visited.
    public var totalDirectoryCount: Int { directories.count }



    /// True when nothing was blocked and nothing was skipped, i.e. the figures
    /// can be treated as a complete account of what was scanned.
    public var isComplete: Bool { deniedPaths.isEmpty && skippedMounts.isEmpty }

    /// True when any denial looks like it could be fixed by Full Disk Access.
    /// Privacy-protected folders such as `~/Library/Mail` return `EACCES` even
    /// to a perfectly healthy Terminal session, so we treat any permission denial
    /// as potentially FDA-gated rather than trying to be clever about which ones.
    public var hasPermissionDenials: Bool {
        deniedPaths.contains { $0.reason == .permissionDenied }
    }
}

/// What `df` and APNS think about a volume, used to cross-check our own totals.
public struct VolumeUsage: Sendable, Codable, Identifiable {
    public let volumeName: String
    public let mountPoint: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let availableBytes: Int64

    public var id: String { mountPoint }

    public var usedBytes: Int64 { totalBytes - freeBytes }

    public func fractionUsed(_ fraction: Double) -> Int64 { Int64(Double(totalBytes) * fraction) }

    public init(
        volumeName: String,
        mountPoint: String,
        totalBytes: Int64,
        freeBytes: Int64,
        availableBytes: Int64
    ) {
        self.volumeName = volumeName
        self.mountPoint = mountPoint
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.availableBytes = availableBytes
    }
}
