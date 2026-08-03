import Foundation

private final class SFTPProgressParser: @unchecked Sendable {
    private let totalBytes: Int64
    private let progress: TransferProgressHandler
    private let lock = NSLock()
    private var unfinishedLine = ""
    private var lastCompletedBytes: Int64 = 0

    init(totalBytes: Int64, progress: @escaping TransferProgressHandler) {
        self.totalBytes = totalBytes
        self.progress = progress
    }

    func consume(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self)
        lock.lock()
        let text = unfinishedLine + chunk
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" })
        let hasTerminator = text.last == "\r" || text.last == "\n"
        unfinishedLine = hasTerminator ? "" : String(lines.last ?? "")
        let completedLines = hasTerminator ? lines : lines.dropLast()
        var completedValues = [Int64]()
        for line in completedLines {
            guard let percentageToken = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first(where: { $0.hasSuffix("%") }),
                  let percentage = Double(percentageToken.dropLast()) else { continue }
            let completed = min(totalBytes, max(lastCompletedBytes, Int64((percentage / 100) * Double(totalBytes))))
            guard completed > lastCompletedBytes else { continue }
            lastCompletedBytes = completed
            completedValues.append(completed)
        }
        lock.unlock()
        completedValues.forEach { progress($0, totalBytes) }
    }
}

actor SFTPRemoteClient: RemoteClient {
    private let profile: ConnectionProfile
    private let endpoint: RemoteEndpoint
    private let secret: String?
    private let knownHostsURL: URL

    init(profile: ConnectionProfile, secret: String?) throws {
        let endpoint = try RemoteEndpoint(profile: profile)
        self.profile = endpoint.profile
        self.endpoint = endpoint
        self.secret = secret
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudShelf", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.knownHostsURL = root.appendingPathComponent("known_hosts")
        if !FileManager.default.fileExists(atPath: knownHostsURL.path) {
            FileManager.default.createFile(atPath: knownHostsURL.path, contents: nil)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: knownHostsURL.path)
        }
    }

    func list(at path: String) async throws -> [RemoteItem] {
        let output = try await execute(["ls -la \(quoted(endpoint.serverPath(for: path)))"])
        return UnixListingParser.parse(output.stdout, parent: RemotePath.normalized(path))
    }

    func createDirectory(named name: String, in parent: String) async throws {
        try validateName(name)
        _ = try await execute(["mkdir \(quoted(endpoint.serverPath(for: RemotePath.join(parent, name))))"])
    }

    func delete(_ item: RemoteItem) async throws {
        if item.isDirectory {
            for child in try await list(at: item.path) { try await delete(child) }
            _ = try await execute(["rmdir \(quoted(endpoint.serverPath(for: item.path)))"])
        } else {
            _ = try await execute(["rm \(quoted(endpoint.serverPath(for: item.path)))"])
        }
    }

    func rename(_ item: RemoteItem, to newName: String) async throws {
        try validateName(newName)
        let destination = RemotePath.join(RemotePath.parent(of: item.path), newName)
        _ = try await execute(["rename \(quoted(endpoint.serverPath(for: item.path))) \(quoted(endpoint.serverPath(for: destination)))"])
    }

    func move(_ item: RemoteItem, to directory: String) async throws {
        let destination = RemotePath.join(directory, item.name)
        _ = try await execute(["rename \(quoted(endpoint.serverPath(for: item.path))) \(quoted(endpoint.serverPath(for: destination)))"])
    }

    func download(_ item: RemoteItem, to localURL: URL) async throws {
        try await download(item, to: localURL, resumeFrom: 0, progress: nil)
    }

    func supportsResumableTransfers() async -> Bool { true }

    func download(_ item: RemoteItem, to localURL: URL, resumeFrom: Int64, progress: TransferProgressHandler?) async throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let command = resumeFrom > 0 ? "reget -p" : "get -p"
        _ = try await execute(
            ["\(command) \(quoted(endpoint.serverPath(for: item.path))) \(quoted(localURL.path))"],
            progress: progress,
            totalBytes: item.size
        )
    }

    func upload(_ localURL: URL, to directory: String) async throws {
        try await upload(localURL, to: directory, resumeFrom: 0, progress: nil)
    }

    func upload(_ localURL: URL, to directory: String, resumeFrom: Int64, progress: TransferProgressHandler?) async throws {
        let target = RemotePath.join(directory, localURL.lastPathComponent)
        let resourceValues = try localURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let command: String
        if resourceValues.isDirectory == true {
            command = "put -pr"
        } else {
            command = resumeFrom > 0 ? "reput -p" : "put -p"
        }
        _ = try await execute(
            ["\(command) \(quoted(localURL.path)) \(quoted(endpoint.serverPath(for: target)))"],
            progress: progress,
            totalBytes: resourceValues.isDirectory == true ? nil : Int64(resourceValues.fileSize ?? 0)
        )
    }

    private func execute(
        _ commands: [String],
        progress: TransferProgressHandler? = nil,
        totalBytes: Int64? = nil
    ) async throws -> ProcessOutput {
        let batch = try TemporaryFiles.write(commands.joined(separator: "\n") + "\n", suffix: "sftp")
        defer { try? FileManager.default.removeItem(at: batch) }

        var arguments = [
            "-P", String(profile.port),
            "-b", batch.path,
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "StrictHostKeyChecking=\(profile.hostKeyPolicy == .strict ? "yes" : "accept-new")",
            "-o", "ConnectTimeout=20",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3"
        ]
        var environment: [String: String] = [:]
        var secretURL: URL?
        var askPassURL: URL?

        switch profile.authentication {
        case .password:
            guard let secret else { throw CloudShelfError.missingCredential }
            secretURL = try TemporaryFiles.write(secret, suffix: "secret")
            askPassURL = try TemporaryFiles.write("#!/bin/sh\ncat \"$CLOUDSHELF_ASKPASS_FILE\"\n", suffix: "askpass", permissions: 0o700)
            environment["CLOUDSHELF_ASKPASS_FILE"] = secretURL?.path
            environment["SSH_ASKPASS"] = askPassURL?.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["DISPLAY"] = "cloudshelf:0"
            arguments += ["-o", "BatchMode=no"]
        case .privateKey:
            guard let privateKeyPath = profile.privateKeyPath, !privateKeyPath.isEmpty else {
                throw CloudShelfError.invalidProfile("Choose a private key file for this connection.")
            }
            arguments += ["-i", privateKeyPath, "-o", "BatchMode=yes"]
        case .sshAgent:
            arguments += ["-o", "BatchMode=yes"]
        }
        defer {
            if let secretURL { try? FileManager.default.removeItem(at: secretURL) }
            if let askPassURL { try? FileManager.default.removeItem(at: askPassURL) }
        }

        let destination = profile.username.isEmpty ? profile.host : "\(profile.username)@\(profile.host)"
        arguments.append(destination)
        let parser = progress.flatMap { progress in
            totalBytes.flatMap { $0 > 0 ? SFTPProgressParser(totalBytes: $0, progress: progress) : nil }
        }
        return try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/sftp"),
            arguments: arguments,
            environment: environment,
            onStandardErrorData: { data in parser?.consume(data) }
        )
    }

    private func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), name != ".", name != ".." else {
            throw CloudShelfError.invalidProfile("Names cannot contain a slash or line break.")
        }
    }
}

public enum RemoteClientFactory {
    public static func make(profile: ConnectionProfile) throws -> any RemoteClient {
        let secret = try CredentialStore.load(profileID: profile.id)
        switch profile.protocolType {
        case .ftp:
            return try CurlRemoteClient(profile: profile, password: secret)
        case .webDAV:
            return try WebDAVRemoteClient(profile: profile, password: secret)
        case .sftp:
            return try SFTPRemoteClient(profile: profile, secret: secret)
        }
    }
}
