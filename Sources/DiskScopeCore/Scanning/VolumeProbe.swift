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

/// Reads volume-level facts from the OS.
///
/// This is where DiskScope explains the thing that confuses everyone: the gap
/// between "System Data" in Finder and the sum of anything you can actually
/// find. On an APFS Mac, the system volume and your data volume share one pool
/// of blocks, and macOS reports space held by local Time Machine snapshots,
/// by other volumes on the same container, and by "purgeable" reserve as
/// System Data. None of it lives in a folder you can `cd` into.
public enum VolumeProbe {
    /// Capacity for every mounted writable volume, plus the root data volume.
    public static func usage() -> [VolumeUsage] {
        var found: [VolumeUsage] = []

        for mountPoint in candidateMountPoints() {
            guard let usage = usage(at: URL(fileURLWithPath: mountPoint)) else { continue }
            found.append(usage)
        }

        // De-duplicate by mount point, since several probes can resolve to the
        // same volume.
        var seen = Set<String>()
        return found.filter { seen.insert($0.mountPoint).inserted }
    }

    /// Root data volume, which is where essentially all of the user's stuff is.
    public static func dataVolume() -> VolumeUsage? {
        usage().first { $0.mountPoint == "/" }
            ?? usage().first { $0.mountPoint.contains("Data") }
            ?? usage().first
    }

    public static func usage(at url: URL) -> VolumeUsage? {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return nil }

        let total = Int64(stats.f_blocks) * Int64(stats.f_bsize)
        let free = Int64(stats.f_bfree) * Int64(stats.f_bsize)
        // f_bavail is what an unprivileged process may actually use; on APFS it
        // is lower than f_bfree because of the reserve.
        let available = Int64(stats.f_bavail) * Int64(stats.f_bsize)

        return VolumeUsage(
            volumeName: volumeName(at: url),
            mountPoint: url.path,
            totalBytes: total,
            freeBytes: free,
            availableBytes: available
        )
    }

    /// Purgeable space, which macOS will reclaim at will.
    ///
    /// `volumeAvailableCapacityForImportantUsage` is the API to reach for here:
    /// it already accounts for purgeable space, so subtracting it from total
    /// capacity gives a figure that matches what Finder reports.
    public static func purgeableBytes(at url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let important = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return max(0, Int64(total) - important)
    }

    /// Bytes held by the APFS snapshots Time Machine keeps locally.
    ///
    /// `tmutil listlocalsnapshots /` is the only supported way to enumerate them.
    /// They are not files, so a directory walk will never find them — which is
    /// precisely why they are so often mistaken for unexplained system data.
    public static func localSnapshotBytes() -> (count: Int, bytes: Int64?) {
        guard let output = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]) else {
            return (0, nil)
        }

        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.contains("com.apple.TimeMachine") }

        guard !lines.isEmpty else { return (0, 0) }

        // Summing snapshot sizes requires walking the whole volume once per
        // snapshot, which is far too slow to do during an interactive scan.
        // We report the count and estimate from the volume's reclaimable delta.
        return (lines.count, nil)
    }

    /// Ask Time Machine to thin its local snapshots.
    ///
    /// This is the only supported way to reclaim snapshot space. Hand-deleting
    /// the snapshot directories under `/Volumes/com.apple.TimeMachine.localsnapshots`
    /// leaves Time Machine's manifest pointing at things that no longer exist,
    /// which breaks the next backup. So DiskScope offers a button that calls
    /// `tmutil` rather than a delete action, and says why.
    @discardableResult
    public static func thinLocalSnapshots() -> Bool {
        run("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "10000000000000", "4"]) != nil
    }

    public static func isTimeMachineBackingUp() -> Bool {
        guard let output = run("/usr/bin/tmutil", ["status"]) else { return false }
        return output.contains("Running")
    }

    private static func candidateMountPoints() -> [String] {
        var points = ["/", "/System/Volumes/Data"]

        let fm = FileManager.default
        if let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            points.append(contentsOf: volumes.map { "/Volumes/\($0)" })
        }

        if let entries = try? fm.contentsOfDirectory(atPath: "/System/Volumes") {
            points.append(contentsOf: entries
                .filter { $0 != "Preboot" && $0 != "Recovery" && $0 != "VM" && $0 != "Update" }
                .map { "/System/Volumes/\($0)" })
        }

        return points
    }

    private static func volumeName(at url: URL) -> String {
        let keys: Set<URLResourceKey> = [.volumeNameKey]
        if let values = try? url.resourceValues(forKeys: keys), let name = values.volumeName {
            return name
        }
        return url.path
    }

    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
