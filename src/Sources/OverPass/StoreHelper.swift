import Foundation

// The built-in store libraries (EpicStore, GOGStore) drive an open-source store client that OverPass downloads as
// a component and runs as a separate program. Each prints JSON on stdout and its log on stderr.
enum StoreHelper {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    enum Failure: LocalizedError {
        case notInstalled(String), message(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled(let name): "The \(name) component isn't installed. Install it from Settings › Components."
            case .message(let text): text
            }
        }
    }

    /// The last error the helper logged ("[cli] ERROR: …"), or the fallback.
    static func failure(_ result: Result, or fallback: String) -> String {
        let line = result.stderr.split(separator: "\n").last { $0.contains("ERROR") || $0.contains("CRITICAL") }
        return line.map { String($0.split(separator: ":", maxSplits: 2).last ?? $0).trimmingCharacters(in: .whitespaces) } ?? fallback
    }

    /// Runs the helper to the end. `started` hands over the process (to stop it); `stderrLine` and `stdoutLine`
    /// get each line as it arrives, for progress.
    static func run(_ tool: URL, name: String, _ args: [String], environment: [String: String],
                    started: (@MainActor (Process) -> Void)? = nil,
                    stderrLine: (@MainActor (String) -> Void)? = nil,
                    stdoutLine: (@MainActor (String) -> Void)? = nil) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { throw Failure.notInstalled(name) }
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let collected = Collected()
        out.fileHandleForReading.readabilityHandler = { handle in
            for line in collected.appendOut(handle.availableData) {
                if let stdoutLine { Task { @MainActor in stdoutLine(line) } }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            for line in collected.appendErr(handle.availableData) {
                if let stderrLine { Task { @MainActor in stderrLine(line) } }
            }
        }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
                if let started { Task { @MainActor in started(process) } }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.appendOut(out.fileHandleForReading.readDataToEndOfFile())
        _ = collected.appendErr(err.fileHandleForReading.readDataToEndOfFile())
        return Result(status: status, stdout: collected.out, stderr: collected.err)
    }

    /// Stops a helper and the worker processes it started. A later install resumes.
    static func interrupt(_ process: Process) {
        let pid = process.processIdentifier
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-INT", "-P", "\(pid)"]
        try? pkill.run()
        kill(pid, SIGINT)
    }

    /// Output gathered from the pipes' handler threads, split into whole lines as they arrive.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var out = Data()
        private(set) var err = ""
        private var partial = ""
        private var partialOut = ""

        @discardableResult
        func appendOut(_ data: Data) -> [String] {
            lock.withLock {
                out.append(data)
                partialOut += String(decoding: data, as: UTF8.self)
                var lines = partialOut.components(separatedBy: "\n")
                partialOut = lines.removeLast()
                return lines
            }
        }

        func appendErr(_ data: Data) -> [String] {
            lock.withLock {
                partial += String(decoding: data, as: UTF8.self)
                var lines = partial.components(separatedBy: "\n")
                partial = lines.removeLast()
                err += lines.map { $0 + "\n" }.joined()
                return lines
            }
        }
    }
}
