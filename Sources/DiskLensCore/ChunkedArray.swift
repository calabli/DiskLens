/// An append-only array stored in fixed-size chunks that never move.
///
/// Copying the struct copies only the list of chunks, so a copy taken during a
/// scan (a snapshot) costs almost nothing and keeps reading the elements below
/// its own `count` while the original goes on appending past it. Elements are
/// never changed once appended, and only the original appends; copies are read-only.
public struct ChunkedArray<Element: BitwiseCopyable>: @unchecked Sendable, ExpressibleByArrayLiteral {
    private static var shift: Int { 16 }
    static var chunkSize: Int { 1 << shift }
    private static var mask: Int { chunkSize - 1 }

    private final class Chunk {
        let base = UnsafeMutablePointer<Element>.allocate(capacity: ChunkedArray.chunkSize)
        deinit { base.deallocate() }
    }

    private var chunks: [Chunk] = []
    public private(set) var count = 0

    public init() {}

    public init(arrayLiteral elements: Element...) {
        for element in elements { append(element) }
    }

    public subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "index \(index) out of range 0..<\(count)")
        return chunks[index >> Self.shift].base[index & Self.mask]
    }

    mutating func append(_ element: Element) {
        if count >> Self.shift == chunks.count { chunks.append(Chunk()) }
        (chunks[chunks.count - 1].base + (count & Self.mask)).initialize(to: element)
        count += 1
    }

    /// Appends `elements` so they sit together in one chunk, skipping to the next
    /// chunk if they do not fit in this one. Returns the index of the first one.
    mutating func appendContiguous(_ elements: UnsafeBufferPointer<Element>) -> Int {
        precondition(elements.count <= Self.chunkSize)
        let slot = count & Self.mask
        if slot != 0 && elements.count > Self.chunkSize - slot {
            count += Self.chunkSize - slot
        }
        if count >> Self.shift == chunks.count { chunks.append(Chunk()) }
        let start = count
        if let source = elements.baseAddress, !elements.isEmpty {
            (chunks[chunks.count - 1].base + (start & Self.mask)).update(from: source, count: elements.count)
        }
        count += elements.count
        return start
    }

    /// Calls `body` with a range written by `appendContiguous`.
    func withContiguous<R>(start: Int, count length: Int, _ body: (UnsafeBufferPointer<Element>) -> R) -> R {
        guard length > 0 else { return body(UnsafeBufferPointer(start: nil, count: 0)) }
        precondition(start >= 0 && start + length <= count && (start & Self.mask) + length <= Self.chunkSize)
        let chunk = chunks[start >> Self.shift]
        return withExtendedLifetime(chunk) {
            body(UnsafeBufferPointer(start: chunk.base + (start & Self.mask), count: length))
        }
    }
}
