import Foundation

struct ProcessOutput: Sendable {
    let stdout: String
    let stderr: String
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> ProcessOutput {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("CloudShelf-output-\(UUID().uuidString)")
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("CloudShelf-error-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let stdout = try FileHandle(forWritingTo: outputURL)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        try stdout.close()
        try stderr.close()
        let output = String(data: try Data(contentsOf: outputURL), encoding: .utf8) ?? ""
        let error = String(data: try Data(contentsOf: errorURL), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CloudShelfError.commandFailed(message.isEmpty ? "Remote command failed with status \(process.terminationStatus)." : message)
        }
        return ProcessOutput(stdout: output, stderr: error)
    }
}

enum TemporaryFiles {
    static func write(_ contents: String, suffix: String, permissions: Int16 = 0o600) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudShelf-\(UUID().uuidString).\(suffix)")
        guard let data = contents.data(using: .utf8) else { throw CloudShelfError.invalidResponse("Could not encode temporary data.") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: permissions)], ofItemAtPath: url.path)
        return url
    }
}
