import Foundation

actor SFTPRemoteClient: RemoteClient {
    private let profile: ConnectionProfile
    private let endpoint: RemoteEndpoint
    private let secret: String?
    private let knownHostsURL: URL

    init(profile: ConnectionProfile, secret: String?) throws {
        self.profile = profile
        self.endpoint = try RemoteEndpoint(profile: profile)
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
        let output = try execute(["ls -la \(quoted(endpoint.serverPath(for: path)))"])
        return UnixListingParser.parse(output.stdout, parent: RemotePath.normalized(path))
    }

    func createDirectory(named name: String, in parent: String) async throws {
        try validateName(name)
        _ = try execute(["mkdir \(quoted(endpoint.serverPath(for: RemotePath.join(parent, name))))"])
    }

    func delete(_ item: RemoteItem) async throws {
        if item.isDirectory {
            for child in try await list(at: item.path) { try await delete(child) }
            _ = try execute(["rmdir \(quoted(endpoint.serverPath(for: item.path)))"])
        } else {
            _ = try execute(["rm \(quoted(endpoint.serverPath(for: item.path)))"])
        }
    }

    func rename(_ item: RemoteItem, to newName: String) async throws {
        try validateName(newName)
        let destination = RemotePath.join(RemotePath.parent(of: item.path), newName)
        _ = try execute(["rename \(quoted(endpoint.serverPath(for: item.path))) \(quoted(endpoint.serverPath(for: destination)))"])
    }

    func move(_ item: RemoteItem, to directory: String) async throws {
        let destination = RemotePath.join(directory, item.name)
        _ = try execute(["rename \(quoted(endpoint.serverPath(for: item.path))) \(quoted(endpoint.serverPath(for: destination)))"])
    }

    func download(_ item: RemoteItem, to localURL: URL) async throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try execute(["get -p \(quoted(endpoint.serverPath(for: item.path))) \(quoted(localURL.path))"])
    }

    func upload(_ localURL: URL, to directory: String) async throws {
        let target = RemotePath.join(directory, localURL.lastPathComponent)
        let resourceValues = try localURL.resourceValues(forKeys: [.isDirectoryKey])
        let command = resourceValues.isDirectory == true ? "put -pr" : "put -p"
        _ = try execute(["\(command) \(quoted(localURL.path)) \(quoted(endpoint.serverPath(for: target)))"])
    }

    private func execute(_ commands: [String]) throws -> ProcessOutput {
        let batch = try TemporaryFiles.write(commands.joined(separator: "\n") + "\n", suffix: "sftp")
        defer { try? FileManager.default.removeItem(at: batch) }

        var arguments = [
            "-P", String(profile.port),
            "-b", batch.path,
            "-o", "UserKnownHostsFile=\(knownHostsURL.path)",
            "-o", "StrictHostKeyChecking=\(profile.hostKeyPolicy == .strict ? "yes" : "accept-new")"
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
        return try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/sftp"), arguments: arguments, environment: environment)
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
        case .ftp, .webDAV:
            return try CurlRemoteClient(profile: profile, password: secret)
        case .sftp:
            return try SFTPRemoteClient(profile: profile, secret: secret)
        }
    }
}
