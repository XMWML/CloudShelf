import Foundation

struct ProcessOutput: Sendable {
    let stdout: String
    let stderr: String
}

private final class ProcessErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var contents = Data()

    func append(_ data: Data) {
        lock.lock()
        contents.append(data)
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return contents
    }
}

private final class ProcessExecution: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var cancellationRequested = false
    private var didFinish = false
    private var continuation: CheckedContinuation<Void, Error>?

    init(process: Process) { self.process = process }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if cancellationRequested || Task.isCancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            process.terminationHandler = { [weak self] _ in self?.finish(.success(())) }
            var startError: Error?
            do {
                try process.run()
            } catch {
                startError = error
            }
            let shouldCancel = cancellationRequested
            lock.unlock()
            if let startError { finish(.failure(startError)) }
            else if shouldCancel { process.terminate() }
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let isRunning = process.isRunning
        lock.unlock()
        if isRunning { process.terminate() }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !didFinish, let continuation else {
            lock.unlock()
            return
        }
        didFinish = true
        self.continuation = nil
        lock.unlock()
        switch result {
        case .success: continuation.resume()
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}

enum ProcessRunner {
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        onStandardErrorData: (@Sendable (Data) -> Void)? = nil
    ) async throws -> ProcessOutput {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("CloudShelf-output-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let stdout = try FileHandle(forWritingTo: outputURL)
        defer { try? stdout.close() }
        let errorPipe = Pipe()
        let errorCollector = ProcessErrorCollector()
        let errorReader = errorPipe.fileHandleForReading
        errorReader.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            errorCollector.append(data)
            onStandardErrorData?(data)
        }
        defer {
            errorReader.readabilityHandler = nil
            try? errorReader.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = stdout
        process.standardError = errorPipe
        let execution = ProcessExecution(process: process)
        try Task.checkCancellation()
        try await withTaskCancellationHandler(operation: {
            try await execution.run()
        }, onCancel: {
            execution.cancel()
        })
        try Task.checkCancellation()

        try stdout.close()
        let output = String(data: try Data(contentsOf: outputURL), encoding: .utf8) ?? ""
        let remainingError = try errorReader.readToEnd() ?? Data()
        if !remainingError.isEmpty {
            errorCollector.append(remainingError)
            onStandardErrorData?(remainingError)
        }
        let error = String(decoding: errorCollector.value(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let message = failureMessage(from: error)
            throw CloudShelfError.commandFailed(message.isEmpty ? "Remote command failed with status \(process.terminationStatus)." : message)
        }
        return ProcessOutput(stdout: output, stderr: error)
    }

    private static func failureMessage(from error: String) -> String {
        let lines = error
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let meaningful = lines.filter { line in
            let firstToken = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            let isProgressMeterLine = firstToken.flatMap { Int($0) } != nil
            return !line.hasPrefix("% Total") &&
                !line.hasPrefix("Dload") &&
                !isProgressMeterLine
        }
        return (meaningful.isEmpty ? lines : meaningful).suffix(3).joined(separator: "\n")
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
