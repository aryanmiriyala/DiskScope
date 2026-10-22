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
import Darwin

/// Bulk directory attribute fetching using `getattrlistbulk`.
///
/// One syscall returns the attributes of every entry in a directory, which is
/// where most of a scan's wall-clock time used to go. `FileSystemScanner` keeps
/// its `fstatat` path as the fallback for anything this cannot handle.
///
/// ## The buffer layout
///
/// `getattrlistbulk` has no published struct for what it writes back, so the
/// layout below was read out of the kernel's own output and is checked against
/// `fstatat` by the test suite. That check matters: a misparsed field does not
/// crash, it just reports the wrong number, and a disk analyzer that quietly
/// miscounts is worse than one that is slow.
///
/// Each record is laid out as:
///
///     0x00  uint32   length of this record, header included
///     0x04  uint32   the attributes the kernel actually returned
///     0x08  uint64   reserved
///     0x10  uint64   reserved
///     0x18  uint32   offset of the variable block, relative to this field
///     0x1c  uint32   size of the variable block
///     0x20  ...      the fixed-size attributes
///           ...      the variable block: the name, then a NUL
///
/// The fixed-size attributes are packed in ascending bit order, common
/// attributes first and then file attributes.
internal enum BulkAttributeFetcher {

    /// The common attributes we ask for.
    ///
    /// Only what the scanner actually reads is requested. Every attribute costs
    /// space in a buffer whose size decides how many entries fit before the
    /// kernel has to stop early, so asking for a nice-to-have means asking for
    /// fewer entries.
    private static let commonBitmap: UInt32 = {
        var b: UInt32 = 0
        b |= UInt32(ATTR_CMN_NAME)
        b |= UInt32(ATTR_CMN_RETURNED_ATTRS)  // REQUIRED by getattrlistbulk
        b |= UInt32(ATTR_CMN_OBJTYPE)
        b |= UInt32(ATTR_CMN_MODTIME)
        b |= UInt32(ATTR_CMN_FILEID)
        b |= UInt32(ATTR_CMN_PARENTID)
        return b
    }()

    /// The file attributes we ask for.
    private static let fileBitmap: UInt32 = {
        var b: UInt32 = 0
        b |= UInt32(ATTR_FILE_LINKCOUNT)
        b |= UInt32(ATTR_FILE_TOTALSIZE)
        b |= UInt32(ATTR_FILE_ALLOCSIZE)
        return b
    }()

    /// Common attributes and their sizes, in the order the kernel packs them.
    private static let commonLayout: [(bit: UInt32, size: Int)] = [
        (UInt32(ATTR_CMN_OBJTYPE), 4),
        (UInt32(ATTR_CMN_MODTIME), 16),
        (UInt32(ATTR_CMN_FILEID), 8),
        (UInt32(ATTR_CMN_PARENTID), 8),
    ]

    /// File attributes and their sizes, in the order the kernel packs them.
    private static let fileLayout: [(bit: UInt32, size: Int)] = [
        (UInt32(ATTR_FILE_LINKCOUNT), 4),
        (UInt32(ATTR_FILE_TOTALSIZE), 8),
        (UInt32(ATTR_FILE_ALLOCSIZE), 8),
    ]

    /// Bytes of fixed header in front of every record.
    private static let headerSize = 0x20

    /// Offset of the field holding the variable block's offset.
    private static let variableOffsetField = 0x18
    /// Offset of the field holding the variable block's size.
    private static let variableSizeField = 0x1c

    /// Longest a file name can be, so we can bound a record's size.
    private static let maximumNameLength = 255

    /// Size of the buffer handed to the kernel.
    ///
    /// A record runs to roughly a hundred bytes — the header, the fixed
    /// attributes and the name — so this holds about two and a half thousand
    /// entries. Directories larger than that are not truncated: the fetcher
    /// notices the buffer filled up and reports the result as incomplete, and
    /// the scanner falls back to reading them one by one.
    private static let bufferSize = 256 * 1024

    /// Result of one bulk fetch.
    struct Result: Sendable {
        let entries: [Entry]

        /// False when the kernel stopped early because the buffer filled up.
        ///
        /// The kernel cannot resume where it left off, so a truncated fetch
        /// means the directory has entries we never saw. Reporting those as
        /// complete would under-count the directory, so the caller falls back.
        let isComplete: Bool
    }

    /// One entry's attributes.
    struct Entry: Sendable {
        let name: String
        let objType: UInt32       // VREG, VDIR, VLNK, ...
        let inode: UInt64         // the file's inode number
        let parentID: UInt64      // the containing directory's inode number
        let modTimeSeconds: Int64
        let modTimeNanoseconds: Int64
        let linkCount: UInt32
        let logicalSize: Int64
        let allocatedSize: Int64

        var isDirectory: Bool { objType == 2 }      // VDIR = 2
        var isRegularFile: Bool { objType == 1 }    // VREG = 1
        var isSymlink: Bool { objType == 5 }        // VLNK = 5
    }

    /// Fetch all entries in a directory using a single `getattrlistbulk` call.
    ///
    /// Returns nil when the syscall is unavailable or the output cannot be
    /// parsed with confidence, in which case the caller should fall back to the
    /// `fstatat` path.
    static func fetchEntries(at url: URL) -> Result? {
        var attrList = attrlist()
        attrList.bitmapcount = UInt16(truncatingIfNeeded: ATTR_BIT_MAP_COUNT)
        attrList.commonattr = commonBitmap
        attrList.fileattr = fileBitmap
        attrList.dirattr = 0

        // Raw memory rather than a Swift array: the kernel fills the buffer, so
        // there is no reason to zero it first, and zeroing a quarter of a
        // megabyte per directory is a measurable cost on a large tree.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let count = getattrlistbulk(fd, &attrList, buffer, bufferSize, 0)
        guard count > 0 else { return nil }

        // `getattrlistbulk` reports how many *entries* it wrote, not how many
        // bytes. An earlier version treated it as a byte count, so it parsed
        // the first few bytes of one record, found nothing sensible, and fell
        // back to `fstatat` on every single directory — the fast path was
        // never actually running.
        guard let parsed = parse(buffer: buffer, limit: bufferSize, entryCount: Int(count)) else {
            return nil
        }
        let (entries, bytesUsed) = parsed
        guard !entries.isEmpty else { return nil }

        // The kernel writes records until the next one will not fit, and it
        // cannot resume afterwards. If there was still room for a whole
        // maximum-size record, then every entry in the directory was written.
        let maximumRecordSize = headerSize
            + commonLayout.reduce(0) { $0 + $1.size }
            + fileLayout.reduce(0) { $0 + $1.size }
            + maximumNameLength + 1 + 7   // the trailing NUL and padding

        let isComplete = bytesUsed + maximumRecordSize <= bufferSize

        return Result(entries: entries, isComplete: isComplete)
    }

    /// Parse the records the kernel wrote.
    ///
    /// Returns the entries and how many bytes of the buffer they occupied, or
    /// nil when any record could not be parsed. A record we cannot read is not
    /// an entry we may drop: the directory would then be under-counted without
    /// anyone noticing. Failing the whole fetch instead sends the caller to
    /// the `fstatat` path, which reads the same directory the slow, honest way.
    private static func parse(
        buffer: UnsafeMutableRawPointer,
        limit: Int,
        entryCount: Int
    ) -> ([Entry], Int)? {
        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)

        var offset = 0
        while entries.count < entryCount {
            guard offset + headerSize <= limit else { break }

            let recordLength = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard recordLength >= headerSize, offset + recordLength <= limit else { break }

            guard let entry = parseRecord(buffer: buffer, at: offset, length: recordLength) else {
                return nil
            }
            entries.append(entry)

            offset += recordLength
        }

        return (entries, offset)
    }

    /// Parse a single record.
    ///
    /// Returns nil when the record does not match the layout we expect, which
    /// means the kernel returned something we do not understand. The caller
    /// treats that as a reason to use the `fstatat` path rather than to guess.
    private static func parseRecord(
        buffer: UnsafeMutableRawPointer,
        at offset: Int,
        length: Int
    ) -> Entry? {
        let returnedAttrs = buffer.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
        let variableOffset = Int(buffer.loadUnaligned(fromByteOffset: offset + variableOffsetField, as: UInt32.self))
        let variableSize = Int(buffer.loadUnaligned(fromByteOffset: offset + variableSizeField, as: UInt32.self))

        let fixedStart = offset + headerSize
        let nameStart = offset + variableOffsetField + variableOffset
        let nameLength = variableSize - 1

        guard nameLength >= 0, nameStart >= fixedStart, nameStart + nameLength <= offset + length else {
            return nil
        }

        var cursor = fixedStart
        var objType: UInt32 = 0
        var inode: UInt64 = 0
        var parentID: UInt64 = 0
        var modSeconds: Int64 = 0
        var modNanoseconds: Int64 = 0
        var linkCount: UInt32 = 1
        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0

        for attribute in commonLayout {
            guard returnedAttrs & attribute.bit != 0 else { continue }
            switch attribute.bit {
            case UInt32(ATTR_CMN_OBJTYPE):
                objType = buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            case UInt32(ATTR_CMN_MODTIME):
                modSeconds = buffer.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
                modNanoseconds = buffer.loadUnaligned(fromByteOffset: cursor + 8, as: Int64.self)
            case UInt32(ATTR_CMN_FILEID):
                // The file id is the object number of the entry, which is the
                // same number `fstatat` reports as the inode.
                inode = buffer.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
            case UInt32(ATTR_CMN_PARENTID):
                parentID = buffer.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
            default:
                break
            }
            cursor += attribute.size
        }

        for attribute in fileLayout {
            // Directories carry directory attributes where other entries
            // carry file attributes. We ask for no directory attributes, so a
            // directory's fixed area ends right after the common ones — and
            // reading file attributes there would run the cursor past the end
            // of the record, which the check below catches.
            guard objType != 2 else { break }

            switch attribute.bit {
            case UInt32(ATTR_FILE_LINKCOUNT):
                linkCount = buffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
            case UInt32(ATTR_FILE_TOTALSIZE):
                logicalSize = buffer.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
            case UInt32(ATTR_FILE_ALLOCSIZE):
                allocatedSize = buffer.loadUnaligned(fromByteOffset: cursor, as: Int64.self)
            default:
                break
            }
            cursor += attribute.size
        }

        // If the fixed area did not end exactly where the name begins, the
        // record is not the shape we think it is. Guessing here would mean
        // reporting plausible-looking numbers that are not the file's.
        guard cursor == nameStart else { return nil }

        let nameBytes = UnsafeRawBufferPointer(start: buffer + nameStart, count: nameLength)
        guard let name = String(bytes: nameBytes, encoding: .utf8) else { return nil }

        return Entry(
            name: name,
            objType: objType,
            inode: inode,
            parentID: parentID,
            modTimeSeconds: modSeconds,
            modTimeNanoseconds: modNanoseconds,
            linkCount: linkCount,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize
        )
    }
}
