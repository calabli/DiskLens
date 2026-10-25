import Darwin

public enum EntryKind: UInt8, Sendable, BitwiseCopyable {
    case file
    case directory
    case symlink
    case other
}

/// One directory entry as returned by `getattrlistbulk`.
struct RawEntry {
    /// Where the name's UTF-8 bytes sit in the `names` buffer passed to `read`.
    var name: Range<Int>
    var kind: EntryKind
    /// Bytes allocated on disk (sum of all forks for files, the directory's own blocks for directories).
    var allocSize: Int64
    var fileID: UInt64
    var linkCount: UInt32
    var device: Int32
    var modTime: Int64
}

/// Reads whole directories in bulk with `getattrlistbulk(2)`, which returns the
/// attributes of many entries per syscall instead of one `stat` per file.
/// Not thread-safe: each worker thread owns its own reader (and buffer).
final class DirectoryReader {
    private let buffer: UnsafeMutableRawBufferPointer
    private var attrs = attrlist()

    init(bufferSize: Int = 256 * 1024) {
        buffer = .allocate(byteCount: bufferSize, alignment: 16)
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = bits(ATTR_CMN_RETURNED_ATTRS) | bits(ATTR_CMN_NAME) | bits(ATTR_CMN_ERROR)
            | bits(ATTR_CMN_DEVID) | bits(ATTR_CMN_OBJTYPE) | bits(ATTR_CMN_MODTIME) | bits(ATTR_CMN_FILEID)
        attrs.dirattr = bits(ATTR_DIR_ALLOCSIZE)
        attrs.fileattr = bits(ATTR_FILE_LINKCOUNT) | bits(ATTR_FILE_ALLOCSIZE)
    }

    deinit {
        buffer.deallocate()
    }

    static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Appends the entries of the open directory `fd` to `entries`, and their
    /// names to `names`. Returns 0 on success or the `errno` that stopped the read.
    /// The caller opens and closes `fd`.
    func read(directory fd: Int32, into entries: inout [RawEntry], names: inout [UInt8]) -> Int32 {
        while true {
            let count = getattrlistbulk(fd, &attrs, buffer.baseAddress, buffer.count, 0)
            if count < 0 { return errno }
            if count == 0 { return 0 }

            var entryStart = buffer.baseAddress!
            for _ in 0..<count {
                let length = entryStart.loadUnaligned(as: UInt32.self)
                if let entry = parse(entryStart, names: &names) {
                    entries.append(entry)
                }
                entryStart += Int(length)
            }
        }
    }

    // Layout per entry: length, returned bitmap, ATTR_CMN_ERROR (always first, see
    // getattrlistbulk(2)), then common, dir and file attributes in bit order.
    // Only attributes flagged in the returned bitmap are present.
    private func parse(_ start: UnsafeMutableRawPointer, names: inout [UInt8]) -> RawEntry? {
        var field = start + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        if returned.commonattr & bits(ATTR_CMN_ERROR) != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
            if error != 0 { return nil }
        }

        var entry = RawEntry(name: names.count..<names.count, kind: .other, allocSize: 0,
                             fileID: 0, linkCount: 1, device: 0, modTime: 0)

        if returned.commonattr & bits(ATTR_CMN_NAME) != 0 {
            let ref = field.loadUnaligned(as: attrreference_t.self)
            let namePtr = (field + Int(ref.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
            // attr_length counts the terminating NUL.
            let length = max(Int(ref.attr_length) - 1, 0)
            let start = names.count
            names.append(contentsOf: UnsafeBufferPointer(start: namePtr, count: length))
            entry.name = start..<names.count
            field += MemoryLayout<attrreference_t>.size
        }
        if returned.commonattr & bits(ATTR_CMN_DEVID) != 0 {
            entry.device = field.loadUnaligned(as: dev_t.self)
            field += MemoryLayout<dev_t>.size
        }
        if returned.commonattr & bits(ATTR_CMN_OBJTYPE) != 0 {
            let type = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
            switch Int(type) {
            case Int(VREG.rawValue): entry.kind = .file
            case Int(VDIR.rawValue): entry.kind = .directory
            case Int(VLNK.rawValue): entry.kind = .symlink
            default: entry.kind = .other
            }
        }
        if returned.commonattr & bits(ATTR_CMN_MODTIME) != 0 {
            entry.modTime = Int64(field.loadUnaligned(as: timespec.self).tv_sec)
            field += MemoryLayout<timespec>.size
        }
        if returned.commonattr & bits(ATTR_CMN_FILEID) != 0 {
            entry.fileID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        if returned.dirattr & bits(ATTR_DIR_ALLOCSIZE) != 0 {
            entry.allocSize = field.loadUnaligned(as: off_t.self)
            field += MemoryLayout<off_t>.size
        }

        if returned.fileattr & bits(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        if returned.fileattr & bits(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocSize = field.loadUnaligned(as: off_t.self)
            field += MemoryLayout<off_t>.size
        }
        return entry
    }
}

@inline(__always)
private func bits(_ value: some BinaryInteger) -> attrgroup_t {
    attrgroup_t(truncatingIfNeeded: value)
}
