/// File names packed as UTF-8 in shared byte chunks. A `String` per name costs
/// 16 bytes plus a heap allocation for names over 15 bytes; this costs the
/// bytes themselves plus 6 bytes of bookkeeping, and snapshots share it all.
public struct NamePool: Sendable, ExpressibleByArrayLiteral {
    private var bytes = ChunkedArray<UInt8>()
    private var starts = ChunkedArray<UInt32>()
    private var lengths = ChunkedArray<UInt16>()

    public init() {}

    public init(arrayLiteral names: String...) {
        for name in names { append(name) }
    }

    public var count: Int { starts.count }

    public subscript(index: Int) -> String {
        bytes.withContiguous(start: Int(starts[index]), count: Int(lengths[index])) {
            String(decoding: $0, as: UTF8.self)
        }
    }

    public mutating func append(_ name: String) {
        Array(name.utf8).withUnsafeBufferPointer { append(bytes: $0) }
    }

    mutating func append(_ name: ArraySlice<UInt8>) {
        name.withUnsafeBufferPointer { append(bytes: $0) }
    }

    private mutating func append(bytes name: UnsafeBufferPointer<UInt8>) {
        // APFS names are at most 255 characters (≤ 765 UTF-8 bytes); only a
        // pathological root path could exceed this.
        let kept = UnsafeBufferPointer(rebasing: name.prefix(Int(UInt16.max)))
        let start = bytes.appendContiguous(kept)
        starts.append(UInt32(start))
        lengths.append(UInt16(kept.count))
    }
}
