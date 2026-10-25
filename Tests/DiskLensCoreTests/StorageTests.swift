import Testing
@testable import DiskLensCore

@Test func chunkedArrayCrossesChunkBoundaries() {
    var array = ChunkedArray<Int32>()
    let n = ChunkedArray<Int32>.chunkSize * 2 + 5
    for i in 0..<n { array.append(Int32(i)) }
    #expect(array.count == n)
    #expect(array[0] == 0)
    #expect(array[ChunkedArray<Int32>.chunkSize - 1] == Int32(ChunkedArray<Int32>.chunkSize - 1))
    #expect(array[ChunkedArray<Int32>.chunkSize] == Int32(ChunkedArray<Int32>.chunkSize))
    #expect(array[n - 1] == Int32(n - 1))
}

@Test func copiesKeepTheirCountWhileTheOriginalGrows() {
    var array: ChunkedArray<Int64> = [1, 2, 3]
    let snapshot = array
    for i in 0..<ChunkedArray<Int64>.chunkSize { array.append(Int64(i)) }
    #expect(snapshot.count == 3)
    #expect(snapshot[2] == 3)
    #expect(array.count == 3 + ChunkedArray<Int64>.chunkSize)
}

@Test func namesNeverStraddleAChunk() {
    var pool = NamePool()
    let long = String(repeating: "é", count: 300)  // 600 UTF-8 bytes
    var expected: [String] = []
    // Enough names to cross several 64 KiB chunks at awkward offsets.
    for i in 0..<400 {
        let name = i % 3 == 0 ? long + "\(i)" : "name-\(i)"
        pool.append(name)
        expected.append(name)
    }
    pool.append("")
    expected.append("")
    #expect(pool.count == expected.count)
    for (i, name) in expected.enumerated() {
        #expect(pool[i] == name)
    }
}
