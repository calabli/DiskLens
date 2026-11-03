import Darwin

/// How much space deleting some items would actually free. APFS clones (what Finder
/// makes when copying a file) share their blocks, so a clone's size counts space that
/// stays in use while another copy remains. Only files the scan flagged as possibly
/// sharing blocks are looked at, so this stays fast for large folders.
public enum FreeableSpace {
    /// Bytes freed by deleting `nodes` (and everything under them) once the Trash is
    /// emptied. Blocks shared with files outside `nodes` stay in use; blocks shared
    /// only between clones inside `nodes` are counted once.
    public static func estimate(_ nodes: [Int], in tree: FileTree) -> Int64 {
        var total = nodes.reduce(Int64(0)) { $0 + tree.totalSizes[$1] }
        // Clone family → how many of its files are being deleted, and its largest shared part.
        var families: [UInt64: (count: Int, shared: Int64)] = [:]
        var stack = nodes
        while let node = stack.popLast() {
            if tree.kinds[node] == .directory {
                stack.append(contentsOf: tree.children(of: node).map(Int.init))
                continue
            }
            guard tree.flags(of: node).contains(.mayShareBlocks), tree.ownSizes[node] > 0,
                  let clone = CloneInfo.of(tree.path(of: node)) else { continue }
            let shared = max(tree.ownSizes[node] - clone.privateSize, 0)
            total -= shared
            if let id = clone.familyID {
                let family = families[id] ?? (0, 0)
                families[id] = (family.count + 1, max(family.shared, shared))
            }
        }
        for family in families.values where family.count > 1 {
            total += family.shared
        }
        return max(total, 0)
    }
}

/// What APFS reports about a file's clones.
struct CloneInfo {
    /// Bytes only this file uses (`ATTR_CMNEXT_PRIVATESIZE`).
    let privateSize: Int64
    /// Shared by a file and the clones made from it (`ATTR_CMNEXT_CLONEID`).
    let familyID: UInt64?

    static func of(_ path: String) -> CloneInfo? {
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        attrs.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes {
            getattrlist(path, &attrs, $0.baseAddress, $0.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return nil }
        return buffer.withUnsafeBytes { raw -> CloneInfo? in
            let returned = raw.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
            var offset = 4 + MemoryLayout<attribute_set_t>.size
            guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
            let privateSize = raw.loadUnaligned(fromByteOffset: offset, as: off_t.self)
            offset += MemoryLayout<off_t>.size
            let familyID = returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0
                ? raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self) : nil
            return CloneInfo(privateSize: privateSize, familyID: familyID)
        }
    }
}
