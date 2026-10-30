import Foundation

/// A command-line tool and its arguments, run directly (never through a shell),
/// so names and paths can never be read as more commands.
public struct ToolCommand: Sendable, Hashable, Codable {
    public let program: String
    public let arguments: [String]

    public init(_ program: String, _ arguments: [String]) {
        self.program = program
        self.arguments = arguments
    }

    /// As a person would type it into Terminal.
    public var display: String {
        ([program] + arguments).map { word in
            word.contains(where: { " '\"\\$`".contains($0) }) ? "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" : word
        }.joined(separator: " ")
    }

    /// Where tools installed by Homebrew, Docker Desktop and Go live, besides the system's own.
    static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/go/bin", "/usr/bin", "/bin", "/usr/sbin"]

    /// The full path of `program`, or nil if it is not installed.
    public static func locate(_ program: String) -> String? {
        if program.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: program) ? program : nil }
        return searchPath.map { $0 + "/" + program }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isInstalled: Bool { Self.locate(program) != nil }

    public struct Result: Sendable {
        public let status: Int32
        public let output: String
        public let errors: String
        public var succeeded: Bool { status == 0 }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notInstalled(String)
        case timedOut

        public var description: String {
            switch self {
            case let .notInstalled(program): "没有找到 \(program)"
            case .timedOut: "命令运行超时"
            }
        }
    }

    /// Runs the command and waits for it, up to `timeout` seconds.
    public func run(timeout: TimeInterval = 30) throws -> Result {
        guard let path = Self.locate(program) else { throw Failure.notInstalled(program) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPath.joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        // Read both pipes while the tool runs, so a chatty tool never blocks on a full pipe.
        let collected = Collected()
        let group = DispatchGroup()
        for (pipe, keyPath) in [(output, \Collected.output), (errors, \Collected.errors)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.set(keyPath, data)
                group.leave()
            }
        }
        try process.run()
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw Failure.timedOut
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: collected.output, as: UTF8.self),
                      errors: String(decoding: collected.errors, as: UTF8.self))
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        var output = Data()
        var errors = Data()

        func set(_ keyPath: ReferenceWritableKeyPath<Collected, Data>, _ data: Data) {
            lock.lock()
            self[keyPath: keyPath] = data
            lock.unlock()
        }
    }
}
