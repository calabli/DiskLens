import Foundation
import SQLite3

/// Per-minute records of disk activity, written by the background agent and
/// read by the app. One SQLite file in WAL mode, so both can use it at once.
public final class ActivityStore: @unchecked Sendable {
    public struct WriteTotal: Sendable, Hashable {
        public let app: String
        public let bytes: Int64
    }

    public struct Growth: Sendable, Hashable {
        public let folder: String
        public let owner: String
        public let bytes: Int64
    }

    public struct VolumePoint: Sendable, Hashable {
        /// Start of the bucket (seconds since 1970).
        public let time: Int64
        /// Used space at the start and end of the bucket.
        public let firstUsed: Int64
        public let lastUsed: Int64

        public var change: Int64 { lastUsed - firstUsed }
    }

    /// ~/Library/Application Support/<bundle id>/activity.sqlite
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("app.disklens.DiskLens").appendingPathComponent("activity.sqlite")
    }

    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL = ActivityStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            == SQLITE_OK else { throw StoreError.cannotOpen(url.path) }
        sqlite3_busy_timeout(db, 2_000)
        try execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS writes (minute INTEGER, app TEXT, bytes INTEGER, PRIMARY KEY (minute, app));
            CREATE TABLE IF NOT EXISTS growth (minute INTEGER, folder TEXT, owner TEXT, bytes INTEGER,
                                               PRIMARY KEY (minute, folder));
            CREATE TABLE IF NOT EXISTS volume (minute INTEGER PRIMARY KEY, used INTEGER, available INTEGER);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT, updated INTEGER);
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    public enum StoreError: Error {
        case cannotOpen(String)
        case sql(String)
    }

    // MARK: Writing (agent)

    /// Adds the bytes each app wrote during `minute` (seconds since 1970, a multiple of 60).
    public func addWrites(_ totals: [String: Int64], minute: Int64) throws {
        try transaction("""
            INSERT INTO writes (minute, app, bytes) VALUES (?, ?, ?)
            ON CONFLICT (minute, app) DO UPDATE SET bytes = bytes + excluded.bytes
            """, rows: totals.filter { $0.value > 0 }.map { [.int(minute), .text($0.key), .int($0.value)] })
    }

    /// Adds net growth (negative for shrinking) of folders during `minute`.
    public func addGrowth(_ changes: [(folder: String, owner: String, bytes: Int64)], minute: Int64) throws {
        try transaction("""
            INSERT INTO growth (minute, folder, owner, bytes) VALUES (?, ?, ?, ?)
            ON CONFLICT (minute, folder) DO UPDATE SET bytes = bytes + excluded.bytes
            """, rows: changes.filter { $0.bytes != 0 }
                .map { [.int(minute), .text($0.folder), .text($0.owner), .int($0.bytes)] })
    }

    public func recordVolume(used: Int64, available: Int64, minute: Int64) throws {
        try transaction("INSERT OR REPLACE INTO volume (minute, used, available) VALUES (?, ?, ?)",
                        rows: [[.int(minute), .int(used), .int(available)]])
    }

    /// Drops records older than `cutoff` (seconds since 1970).
    public func prune(before cutoff: Int64) throws {
        for table in ["writes", "growth", "volume"] {
            try transaction("DELETE FROM \(table) WHERE minute < ?", rows: [[.int(cutoff)]])
        }
    }

    /// A small status value the agent reports for the app, such as its own permissions.
    public func setMeta(_ key: String, _ value: String) throws {
        try transaction("INSERT OR REPLACE INTO meta (key, value, updated) VALUES (?, ?, ?)",
                        rows: [[.text(key), .text(value), .int(Int64(Date().timeIntervalSince1970))]])
    }

    public func meta(_ key: String) -> (value: String, updated: Date)? {
        query("SELECT value, updated FROM meta WHERE key = ?", [.text(key)]) { row in
            (row.text(0), Date(timeIntervalSince1970: TimeInterval(row.int(1))))
        }.first
    }

    // MARK: Reading (app)

    public func topWriters(from start: Int64, to end: Int64, limit: Int = 15) -> [WriteTotal] {
        query("""
            SELECT app, SUM(bytes) AS total FROM writes WHERE minute >= ? AND minute < ?
            GROUP BY app ORDER BY total DESC LIMIT ?
            """, [.int(start), .int(end), .int(Int64(limit))]) { row in
            WriteTotal(app: row.text(0), bytes: row.int(1))
        }
    }

    /// Net growth per owner, largest growth first; owners that shrank come last.
    public func growthByOwner(from start: Int64, to end: Int64, limit: Int = 15) -> [WriteTotal] {
        query("""
            SELECT owner, SUM(bytes) AS total FROM growth WHERE minute >= ? AND minute < ?
            GROUP BY owner HAVING total != 0 ORDER BY total DESC LIMIT ?
            """, [.int(start), .int(end), .int(Int64(limit))]) { row in
            WriteTotal(app: row.text(0), bytes: row.int(1))
        }
    }

    /// The folders behind `owner`'s growth, largest first.
    public func growthFolders(owner: String, from start: Int64, to end: Int64, limit: Int = 10) -> [Growth] {
        query("""
            SELECT folder, owner, SUM(bytes) AS total FROM growth
            WHERE owner = ? AND minute >= ? AND minute < ?
            GROUP BY folder HAVING total != 0 ORDER BY ABS(total) DESC LIMIT ?
            """, [.text(owner), .int(start), .int(end), .int(Int64(limit))]) { row in
            Growth(folder: row.text(0), owner: row.text(1), bytes: row.int(2))
        }
    }

    /// Used space per bucket of `bucket` seconds, oldest first. Buckets start at
    /// multiples of `bucket` shifted by `offset` seconds: pass the time zone's
    /// offset from GMT to make daily buckets start at local midnight.
    public func volumeSeries(from start: Int64, to end: Int64, bucket: Int64, offset: Int64 = 0) -> [VolumePoint] {
        query("""
            SELECT ((minute + ?4) / ?1) * ?1 - ?4 AS b,
                   (SELECT used FROM volume v2
                    WHERE v2.minute >= ((v.minute + ?4) / ?1) * ?1 - ?4 AND v2.minute >= ?2
                    ORDER BY v2.minute ASC LIMIT 1),
                   (SELECT used FROM volume v3
                    WHERE v3.minute < ((v.minute + ?4) / ?1) * ?1 - ?4 + ?1 AND v3.minute < ?3
                    ORDER BY v3.minute DESC LIMIT 1)
            FROM volume v WHERE minute >= ?2 AND minute < ?3 GROUP BY b ORDER BY b
            """, [.int(bucket), .int(start), .int(end), .int(offset)]) { row in
            VolumePoint(time: row.int(0), firstUsed: row.int(1), lastUsed: row.int(2))
        }
    }

    /// The latest minute recorded, if any.
    public func lastRecord() -> Int64? {
        query("SELECT MAX(minute) FROM volume", []) { row in row.isNull(0) ? nil : row.int(0) }.first ?? nil
    }

    /// When recording started, if it has.
    public func firstRecord() -> Int64? {
        query("SELECT MIN(minute) FROM volume", []) { row in row.isNull(0) ? nil : row.int(0) }.first ?? nil
    }

    // MARK: SQLite plumbing

    private enum Value {
        case int(Int64)
        case text(String)
    }

    private struct Row {
        let statement: OpaquePointer?
        func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.sql(lastError()) }
    }

    private func transaction(_ sql: String, rows: [[Value]]) throws {
        guard !rows.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.sql(lastError()) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw StoreError.sql(lastError())
        }
        for row in rows {
            bind(row, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw StoreError.sql(lastError())
            }
            sqlite3_reset(statement)
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.sql(lastError()) }
    }

    private func query<T>(_ sql: String, _ values: [Value], _ map: (Row) -> T) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        bind(values, to: statement)
        var result: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(map(Row(statement: statement)))
        }
        return result
    }

    private func bind(_ values: [Value], to statement: OpaquePointer?) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let .int(number): sqlite3_bind_int64(statement, position, number)
            case let .text(string): sqlite3_bind_text(statement, position, string, -1, Self.transient)
            }
        }
    }

    private func lastError() -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
