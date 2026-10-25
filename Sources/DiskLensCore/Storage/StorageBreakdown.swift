import Foundation

/// How an APFS container's space divides between its volumes, plus purgeable
/// space and local snapshots: the parts of "used" that a scan of your files
/// does not show.
public struct StorageBreakdown: Sendable {
    public enum Role: String, Sendable {
        case system, data, vm, preboot, recovery, update, other
    }

    public struct Volume: Sendable, Identifiable {
        public let name: String
        public let role: Role
        public let used: Int64
        public var id: String { name + role.rawValue }
    }

    public struct Snapshot: Sendable, Identifiable {
        public let name: String
        /// Time Machine snapshots carry their date; system update snapshots do not.
        public let date: Date?
        public var id: String { name }
        public var isTimeMachine: Bool { name.hasPrefix("com.apple.TimeMachine.") }
    }

    public let containerSize: Int64
    public let containerFree: Int64
    public let volumes: [Volume]
    /// Space macOS frees on its own when needed (caches, snapshots, synced iCloud files).
    public let purgeable: Int64
    public let snapshots: [Snapshot]

    public var containerUsed: Int64 { containerSize - containerFree }

    public init(containerSize: Int64, containerFree: Int64, volumes: [Volume], purgeable: Int64,
                snapshots: [Snapshot]) {
        self.containerSize = containerSize
        self.containerFree = containerFree
        self.volumes = volumes
        self.purgeable = purgeable
        self.snapshots = snapshots
    }

    /// Reads the container holding `path` with `diskutil` and `tmutil` (no admin rights needed).
    public static func load(for path: String = "/") throws -> StorageBreakdown {
        let info = try plist(from: run("/usr/sbin/diskutil", ["info", "-plist", path]))
        guard let container = info["APFSContainerReference"] as? String else {
            throw StorageError.notAPFS
        }
        let list = try plist(from: run("/usr/sbin/diskutil", ["apfs", "list", "-plist", container]))
        guard let containers = list["Containers"] as? [[String: Any]], let first = containers.first,
              let size = (first["CapacityCeiling"] as? NSNumber)?.int64Value,
              let free = (first["CapacityFree"] as? NSNumber)?.int64Value
        else { throw StorageError.unexpectedOutput }

        let volumes = (first["Volumes"] as? [[String: Any]] ?? []).map { volume in
            let roles = volume["Roles"] as? [String] ?? []
            return Volume(name: volume["Name"] as? String ?? "?",
                          role: roles.lazy.compactMap { Role(rawValue: $0.lowercased()) }.first ?? .other,
                          used: (volume["CapacityInUse"] as? NSNumber)?.int64Value ?? 0)
        }

        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let purgeable = max((values?.volumeAvailableCapacityForImportantUsage ?? 0)
            - Int64(values?.volumeAvailableCapacity ?? 0), 0)

        return StorageBreakdown(containerSize: size, containerFree: free, volumes: volumes,
                                purgeable: purgeable, snapshots: localSnapshots())
    }

    /// Local snapshots of the data volume (Time Machine, update).
    private static func localSnapshots() -> [Snapshot] {
        guard let output = try? run("/usr/bin/tmutil", ["listlocalsnapshots", "/System/Volumes/Data"]) else { return [] }
        return String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("com.apple.") }
            .map { Snapshot(name: $0, date: snapshotDate($0)) }
    }

    /// "com.apple.TimeMachine.2026-10-24-101530.local" → that date.
    static func snapshotDate(_ name: String) -> Date? {
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: String(name[range]))
    }

    public enum StorageError: Error {
        case notAPFS
        case unexpectedOutput
        case commandFailed(String)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StorageError.commandFailed(tool) }
        return data
    }

    private static func plist(from data: Data) throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw StorageError.unexpectedOutput }
        return dictionary
    }
}
