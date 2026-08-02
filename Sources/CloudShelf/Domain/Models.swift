import Foundation

public enum RemoteProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ftp = "FTP"
    case sftp = "SFTP"
    case webDAV = "WebDAV"

    public var id: String { rawValue }

    public var defaultPort: Int {
        switch self {
        case .ftp: 21
        case .sftp: 22
        case .webDAV: 443
        }
    }

    public var defaultTLS: Bool { self == .webDAV }
}

public enum AuthenticationMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password = "Password"
    case sshAgent = "SSH Agent"
    case privateKey = "Private Key"

    public var id: String { rawValue }
}

public enum HostKeyPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case strict = "Strict"
    case acceptNew = "Accept new keys"

    public var id: String { rawValue }
}

public struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var protocolType: RemoteProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var basePath: String
    public var authentication: AuthenticationMethod
    public var privateKeyPath: String?
    public var useTLS: Bool
    public var hostKeyPolicy: HostKeyPolicy
    public var createdAt: Date
    public var syncRules: [SyncRule]

    public init(
        id: UUID = UUID(),
        name: String,
        protocolType: RemoteProtocol,
        host: String,
        port: Int? = nil,
        username: String = "",
        basePath: String = "/",
        authentication: AuthenticationMethod = .password,
        privateKeyPath: String? = nil,
        useTLS: Bool? = nil,
        hostKeyPolicy: HostKeyPolicy = .acceptNew,
        createdAt: Date = .now,
        syncRules: [SyncRule] = []
    ) {
        self.id = id
        self.name = name
        self.protocolType = protocolType
        self.host = host
        self.port = port ?? protocolType.defaultPort
        self.username = username
        self.basePath = RemotePath.normalized(basePath)
        self.authentication = authentication
        self.privateKeyPath = privateKeyPath
        self.useTLS = useTLS ?? protocolType.defaultTLS
        self.hostKeyPolicy = hostKeyPolicy
        self.createdAt = createdAt
        self.syncRules = syncRules
    }
}

public struct RemoteItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
        case symlink
        case unknown
    }

    public let name: String
    public let path: String
    public let kind: Kind
    public let size: Int64?
    public let modifiedAt: Date?

    public var id: String { path }
    public var isDirectory: Bool { kind == .directory }
    public var fileExtension: String { URL(fileURLWithPath: name).pathExtension }

    public init(name: String, path: String, kind: Kind, size: Int64?, modifiedAt: Date?) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public enum SyncDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case uploadOnly = "Upload local changes"
    case downloadOnly = "Download remote changes"
    case bidirectional = "Keep newest version"

    public var id: String { rawValue }
}

public enum SyncConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case keepNewest = "Keep newest"
    case keepLocal = "Keep local"
    case keepRemote = "Keep remote"
    case duplicate = "Keep both"

    public var id: String { rawValue }
}

public struct SyncRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var localFolder: String
    public var remoteFolder: String
    public var direction: SyncDirection
    public var conflictPolicy: SyncConflictPolicy
    public var intervalMinutes: Int
    public var isEnabled: Bool
    public var syncOnLocalChanges: Bool?
    public var lastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        localFolder: String,
        remoteFolder: String = "/",
        direction: SyncDirection = .uploadOnly,
        conflictPolicy: SyncConflictPolicy = .keepNewest,
        intervalMinutes: Int = 15,
        isEnabled: Bool = true,
        syncOnLocalChanges: Bool = false,
        lastSyncedAt: Date? = nil
    ) {
        self.id = id
        self.localFolder = localFolder
        self.remoteFolder = RemotePath.normalized(remoteFolder)
        self.direction = direction
        self.conflictPolicy = conflictPolicy
        self.intervalMinutes = max(1, intervalMinutes)
        self.isEnabled = isEnabled
        self.syncOnLocalChanges = syncOnLocalChanges
        self.lastSyncedAt = lastSyncedAt
    }
}

public enum TransferDirection: String, Sendable, Equatable {
    case upload
    case download
    case sync
}

public enum TransferStatus: String, Sendable, Equatable {
    case queued
    case running
    case succeeded
    case failed
}

public struct TransferTask: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let direction: TransferDirection
    public let title: String
    public let connectionName: String
    public var status: TransferStatus
    public var detail: String
    public var startedAt: Date?
    public var finishedAt: Date?
    public var completedBytes: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Double?

    public init(
        id: UUID = UUID(),
        direction: TransferDirection,
        title: String,
        connectionName: String,
        status: TransferStatus = .queued,
        detail: String = "Waiting",
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        bytesPerSecond: Double? = nil
    ) {
        self.id = id
        self.direction = direction
        self.title = title
        self.connectionName = connectionName
        self.status = status
        self.detail = detail
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

public enum RemotePath {
    public static func normalized(_ path: String) -> String {
        let cleaned = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "/" }
        let prefixed = cleaned.hasPrefix("/") ? cleaned : "/" + cleaned
        let components = prefixed.split(separator: "/").reduce(into: [String]()) { result, part in
            if part == "." || part.isEmpty { return }
            if part == ".." { _ = result.popLast() } else { result.append(String(part)) }
        }
        return "/" + components.joined(separator: "/")
    }

    public static func join(_ parent: String, _ child: String) -> String {
        normalized(normalized(parent) + "/" + child)
    }

    public static func parent(of path: String) -> String {
        let normalized = normalized(path)
        guard normalized != "/" else { return "/" }
        let components = normalized.split(separator: "/")
        return components.dropLast().isEmpty ? "/" : "/" + components.dropLast().joined(separator: "/")
    }

    public static func name(of path: String) -> String {
        normalized(path).split(separator: "/").last.map(String.init) ?? ""
    }
}
