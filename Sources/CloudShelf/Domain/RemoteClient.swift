import Foundation

public typealias TransferProgressHandler = @Sendable (_ completedBytes: Int64, _ totalBytes: Int64?) -> Void

public protocol RemoteClient: Sendable {
    func list(at path: String) async throws -> [RemoteItem]
    func createDirectory(named name: String, in parent: String) async throws
    func delete(_ item: RemoteItem) async throws
    func rename(_ item: RemoteItem, to newName: String) async throws
    func move(_ item: RemoteItem, to directory: String) async throws
    func download(_ item: RemoteItem, to localURL: URL) async throws
    func upload(_ localURL: URL, to directory: String) async throws
    func download(_ item: RemoteItem, to localURL: URL, progress: TransferProgressHandler?) async throws
    func upload(_ localURL: URL, to directory: String, progress: TransferProgressHandler?) async throws
    func supportsResumableTransfers() async -> Bool
    func download(_ item: RemoteItem, to localURL: URL, resumeFrom: Int64, progress: TransferProgressHandler?) async throws
    func upload(_ localURL: URL, to directory: String, resumeFrom: Int64, progress: TransferProgressHandler?) async throws
    func copy(_ item: RemoteItem, to directory: String) async throws
}

public extension RemoteClient {
    func download(_ item: RemoteItem, to localURL: URL, progress: TransferProgressHandler?) async throws {
        try await download(item, to: localURL)
    }

    func upload(_ localURL: URL, to directory: String, progress: TransferProgressHandler?) async throws {
        try await upload(localURL, to: directory)
    }

    func supportsResumableTransfers() async -> Bool { false }

    func download(_ item: RemoteItem, to localURL: URL, resumeFrom: Int64, progress: TransferProgressHandler?) async throws {
        try await download(item, to: localURL, progress: progress)
    }

    func upload(_ localURL: URL, to directory: String, resumeFrom: Int64, progress: TransferProgressHandler?) async throws {
        try await upload(localURL, to: directory, progress: progress)
    }

    func copy(_ item: RemoteItem, to directory: String) async throws {
        let destination = RemotePath.join(directory, item.name)
        if item.isDirectory {
            try await createDirectory(named: item.name, in: directory)
            for child in try await list(at: item.path) {
                try await copy(child, to: destination)
            }
            return
        }

        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudShelf-copy-\(UUID().uuidString)")
            .appendingPathComponent(item.name)
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        try await download(item, to: local)
        try await upload(local, to: directory)
    }
}

public enum CloudShelfError: LocalizedError, Sendable {
    case invalidProfile(String)
    case missingCredential
    case unsupported(String)
    case commandFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfile(let message), .unsupported(let message), .commandFailed(let message), .invalidResponse(let message):
            message
        case .missingCredential:
            "没有找到已保存的密码。请编辑连接，填写密码后重新保存。"
        }
    }
}
