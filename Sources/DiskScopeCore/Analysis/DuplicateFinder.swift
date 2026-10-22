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

/// Finds byte-identical duplicate files within a scan result.
///
/// Uses a two-phase approach to minimize full file hashing:
/// 1. Group files by size — only files of identical size can be duplicates
/// 2. For each size group with more than one file, compute a sample hash of the
///    head and the tail
/// 3. For the files whose sample hashes collide, compute a full SHA-256
/// 4. Report the groups that are byte-identical
///
/// The candidate files come from the scan's own file table, so the tree is
/// walked once rather than twice.
public struct DuplicateFinderConfiguration: Sendable {
    /// Files smaller than this are not considered.
    public let minimumSize: Int64

    /// How many bytes to read from each end of a file when sampling it.
    public let sampleSize: Int

    /// The most files to hash in one run.
    public let maxFilesToHash: Int

    public init(
        minimumSize: Int64 = 1024 * 1024,
        sampleSize: Int = 64 * 1024,
        maxFilesToHash: Int = 10_000
    ) {
        self.minimumSize = minimumSize
        self.sampleSize = sampleSize
        self.maxFilesToHash = maxFilesToHash
    }
}

/// A set of files that hold exactly the same bytes.
public struct DuplicateFinderGroup: Sendable, Identifiable, Codable {
    /// One copy of the shared content.
    public struct Member: Sendable, Identifiable, Codable, Hashable {
        public let url: URL
        public let logicalSize: Int64
        public let allocatedSize: Int64
        public let modificationDate: Date?

        /// Whether the file has more than one link.
        public let isHardLinked: Bool

        /// The device and inode the file lives on, used to tell two names for
        /// the same file apart from two copies of the same content.
        public let device: UInt64
        public let inode: UInt64

        /// How many links the file has in total, including any outside the
        /// group.
        public let linkCount: Int

        public var id: URL { url }
        public var displayName: String { url.lastPathComponent }

        public init(
            url: URL,
            logicalSize: Int64,
            allocatedSize: Int64,
            modificationDate: Date?,
            isHardLinked: Bool,
            device: UInt64 = 0,
            inode: UInt64 = 0,
            linkCount: Int = 1
        ) {
            self.url = url
            self.logicalSize = logicalSize
            self.allocatedSize = allocatedSize
            self.modificationDate = modificationDate
            self.isHardLinked = isHardLinked
            self.device = device
            self.inode = inode
            self.linkCount = linkCount
        }
    }

    public let id: UUID

    /// The size of one copy.
    public let logicalSize: Int64

    /// The physical size of one copy.
    public let allocatedSize: Int64

    /// The SHA-256 of the shared content, so a claim of "these are the same
    /// file" can be checked.
    public let contentDigest: String

    public let members: [Member]

    public init(
        id: UUID = UUID(),
        logicalSize: Int64,
        allocatedSize: Int64,
        contentDigest: String = "",
        members: [Member]
    ) {
        self.id = id
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.contentDigest = contentDigest
        self.members = members
    }

    public var memberCount: Int { members.count }

    /// The copy worth keeping: the oldest one.
    ///
    /// Keeping the oldest is the convention every file manager uses, and it is
    /// usually the original — the later copies are the ones a copy, a sync or
    /// an "untitled 2" produced.
    public var primaryCopy: Member? {
        members.min { lhs, rhs in
            switch (lhs.modificationDate, rhs.modificationDate) {
            case let (left?, right?): return left < right
            case (nil, _?): return true
            case (_?, nil): return false
            case (nil, nil): return false
            }
        }
    }

    /// How many distinct files the group's names point at.
    ///
    /// Two names for one file are a hard link, not a duplicate copy, and the
    /// difference matters when the number is "space you can get back".
    public var distinctInodeCount: Int {
        Set(members.map { Inode(device: $0.device, inode: $0.inode) }).count
    }

    /// The space that deleting every copy except the primary would release.
    ///
    /// Two things make the obvious calculation wrong. A hard link shares its
    /// blocks with the copy being kept, so deleting it releases nothing. And a
    /// file with links outside the group stays alive when our copies go, so it
    /// releases nothing either. Only the files whose every link is inside the
    /// group actually disappear.
    public var wastedBytes: Int64 {
        guard let primary = primaryCopy else { return 0 }
        let primaryInode = Inode(device: primary.device, inode: primary.inode)

        var copies: [Inode: Int] = [:]
        var allocated: [Inode: Int64] = [:]
        var links: [Inode: Int] = [:]
        for member in members {
            let identity = Inode(device: member.device, inode: member.inode)
            copies[identity, default: 0] += 1
            allocated[identity] = member.allocatedSize
            links[identity] = member.linkCount
        }

        var freed: Int64 = 0
        for (identity, count) in copies {
            // The copy we keep stays on disk, so its blocks are not released.
            guard identity != primaryInode else { continue }
            // `linkCount` counts every link to the file, including any that
            // live outside this group.
            guard count >= links[identity] ?? count else { continue }
            freed += allocated[identity] ?? 0
        }
        return freed
    }

    /// Identifies one file on disk.
    private struct Inode: Hashable {
        let device: UInt64
        let inode: UInt64
    }
}

/// A file we could not fully examine, and why.
public struct DuplicateFinderCaveat: Sendable, Identifiable, Codable {
    public let url: URL
    public let reason: String

    public var id: URL { url }

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// What the duplicate finder found.
public struct DuplicateFinderResult: Sendable {
    public let groups: [DuplicateFinderGroup]

    /// How many candidate files were hashed.
    public let filesConsidered: Int

    /// The total size of the files that were hashed.
    public let bytesConsidered: Int64

    /// Things that stopped the finder from seeing the whole picture.
    public let caveats: [DuplicateFinderCaveat]

    /// True when some candidate files were not examined.
    public let isPartial: Bool

    public init(
        groups: [DuplicateFinderGroup] = [],
        filesConsidered: Int = 0,
        bytesConsidered: Int64 = 0,
        caveats: [DuplicateFinderCaveat] = [],
        isPartial: Bool = false
    ) {
        self.groups = groups
        self.filesConsidered = filesConsidered
        self.bytesConsidered = bytesConsidered
        self.caveats = caveats
        self.isPartial = isPartial
    }

    /// The space the reported groups could release.
    public var totalWastedBytes: Int64 { groups.reduce(0) { $0 + $1.wastedBytes } }

    /// How many files are sitting in the reported groups.
    public var totalFilesInGroups: Int { groups.reduce(0) { $0 + $1.memberCount } }

    public var isEmpty: Bool { groups.isEmpty }
}

/// Finds duplicate files in a scan.
public struct DuplicateFinder: Sendable {
    public let configuration: DuplicateFinderConfiguration

    public init(configuration: DuplicateFinderConfiguration = DuplicateFinderConfiguration()) {
        self.configuration = configuration
    }

    /// Find the byte-identical files in `scan`.
    ///
    /// The scan must have been run with a `largeFileThreshold` no higher than
    /// the configured minimum size, because the candidate files come from the
    /// scan's own file table. When it was not, the finder says so rather than
    /// quietly reporting only what it happened to receive.
    public func findDuplicates(in scan: ScanResult) async -> DuplicateFinderResult {
        var caveats: [DuplicateFinderCaveat] = []

        if scan.largeFileThreshold > configuration.minimumSize {
            caveats.append(DuplicateFinderCaveat(
                url: scan.roots.first ?? URL(fileURLWithPath: "/"),
                reason: "The scan only recorded files of \(ByteFormat.string(scan.largeFileThreshold)) and above, so smaller duplicates were not examined."
            ))
        }

        if scan.largeFilesTruncated {
            caveats.append(DuplicateFinderCaveat(
                url: scan.roots.first ?? URL(fileURLWithPath: "/"),
                reason: "The scan kept only its largest \(ByteFormat.bare(scan.largeFiles.count)) files, so some duplicates may be missing."
            ))
        }

        // The scan records every file at or above its threshold, so anything
        // below the minimum size is filtered out here.
        let candidates = scan.largeFiles.filter { $0.logicalSize >= configuration.minimumSize }

        // Only files of the same size can be duplicates, so the size grouping
        // throws away almost everything before any hashing happens.
        var sizeGroups: [Int64: [LargeFileRecord]] = [:]
        for file in candidates {
            sizeGroups[file.logicalSize, default: []].append(file)
        }

        let candidateGroups = sizeGroups.filter { $0.value.count >= 2 }

        // Spend the hashing budget where it buys the most: the groups that
        // could release the most space come first.
        let orderedGroups = candidateGroups.sorted { left, right in
            let leftValue = Int64(left.value.count - 1) * left.key
            let rightValue = Int64(right.value.count - 1) * right.key
            if leftValue != rightValue { return leftValue > rightValue }
            return left.key > right.key
        }

        var groups: [DuplicateFinderGroup] = []
        var filesHashed = 0
        var bytesHashed: Int64 = 0
        var budget = configuration.maxFilesToHash

        for (index, entry) in orderedGroups.enumerated() {
            let files = entry.value

            guard files.count <= budget else {
                let unexamined = orderedGroups[index...].reduce(0) { $0 + $1.value.count }
                caveats.append(DuplicateFinderCaveat(
                    url: scan.roots.first ?? URL(fileURLWithPath: "/"),
                    reason: "\(unexamined) candidate files were not examined because the limit of \(configuration.maxFilesToHash) hashed files was reached."
                ))
                return DuplicateFinderResult(
                    groups: groups,
                    filesConsidered: filesHashed,
                    bytesConsidered: bytesHashed,
                    caveats: caveats,
                    isPartial: true
                )
            }

            budget -= files.count
            filesHashed += files.count
            bytesHashed += files.reduce(0) { $0 + $1.logicalSize }

            groups.append(contentsOf: findGroups(inSizeGroup: files, caveats: &caveats))
        }

        // Sorted by what they are worth, and then by path, so two runs over the
        // same tree print the same thing.
        groups.sort { left, right in
            if left.wastedBytes != right.wastedBytes { return left.wastedBytes > right.wastedBytes }
            if left.logicalSize != right.logicalSize { return left.logicalSize > right.logicalSize }
            return (left.members.first?.url.path ?? "") < (right.members.first?.url.path ?? "")
        }

        return DuplicateFinderResult(
            groups: groups,
            filesConsidered: filesHashed,
            bytesConsidered: bytesHashed,
            caveats: caveats,
            isPartial: false
        )
    }

    /// Find the duplicate groups inside one size group.
    private func findGroups(
        inSizeGroup files: [LargeFileRecord],
        caveats: inout [DuplicateFinderCaveat]
    ) -> [DuplicateFinderGroup] {
        // The sample hash reads the head and the tail of each file. Two files
        // of the same size with the same head and tail are almost certainly
        // the same file, and reading 128 KB is instant where hashing four
        // gigabytes is not.
        var sampleGroups: [String: [LargeFileRecord]] = [:]
        for file in files {
            do {
                let sample = try SHA256Lite.sampleDigest(
                    ofFileAt: file.url,
                    fileSize: file.logicalSize,
                    headBytes: configuration.sampleSize,
                    tailBytes: configuration.sampleSize
                )
                sampleGroups[SHA256Lite.hexString(sample), default: []].append(file)
            } catch {
                caveats.append(DuplicateFinderCaveat(
                    url: file.url,
                    reason: "Could not be read for comparison: \(error.localizedDescription)"
                ))
            }
        }

        var groups: [DuplicateFinderGroup] = []

        // Only the sample collisions are worth a full hash.
        for (_, collisions) in sampleGroups where collisions.count >= 2 {
            var hashGroups: [String: [LargeFileRecord]] = [:]
            for file in collisions {
                do {
                    let digest = try SHA256Lite.digest(ofFileAt: file.url)
                    hashGroups[SHA256Lite.hexString(digest), default: []].append(file)
                } catch {
                    caveats.append(DuplicateFinderCaveat(
                        url: file.url,
                        reason: "Could not be read in full: \(error.localizedDescription)"
                    ))
                }
            }

            for (digest, identical) in hashGroups where identical.count >= 2 {
                groups.append(makeGroup(from: identical, digest: digest))
            }
        }

        return groups
    }

    /// Build a group from a set of files that hashed to the same value.
    private func makeGroup(from files: [LargeFileRecord], digest: String) -> DuplicateFinderGroup {
        let ordered = files.sorted { $0.url.path < $1.url.path }
        let members = ordered.map { file in
            DuplicateFinderGroup.Member(
                url: file.url,
                logicalSize: file.logicalSize,
                allocatedSize: file.allocatedSize,
                modificationDate: file.modificationDate,
                isHardLinked: file.isHardLinked,
                device: file.device,
                inode: file.inode,
                linkCount: file.linkCount
            )
        }

        return DuplicateFinderGroup(
            logicalSize: members.first?.logicalSize ?? 0,
            allocatedSize: members.first?.allocatedSize ?? 0,
            contentDigest: digest,
            members: members
        )
    }
}
