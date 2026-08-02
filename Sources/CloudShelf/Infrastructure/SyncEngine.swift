import Foundation

public struct SyncReport: Sendable {
    public var uploaded = 0
    public var downloaded = 0
    public var deletedRemote = 0
    public var deletedLocal = 0
    public var skipped = 0
    public var conflicts = 0

    public init() {}
}

public actor SyncEngine {
    private let stateStore: SyncStateStore

    public init(stateDirectory: URL? = nil) {
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudShelf/SyncState", isDirectory: true)
        stateStore = SyncStateStore(directory: stateDirectory ?? defaultDirectory)
    }

    public func removeState(for ruleID: UUID) async {
        await stateStore.remove(ruleID: ruleID)
    }

    public func synchronize(rule: SyncRule, client: any RemoteClient) async throws -> SyncReport {
        let localRoot = URL(fileURLWithPath: rule.localFolder, isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CloudShelfError.invalidProfile("The selected local folder no longer exists.")
        }

        try await ensureRemoteRoot(rule.remoteFolder, client: client)
        var localItems = try localInventory(root: localRoot)
        var remoteItems = try await remoteInventory(client: client, root: rule.remoteFolder)
        var knownRemoteDirectories = Set(remoteItems.values.filter(\.isDirectory).map(\.path))
        knownRemoteDirectories.insert(RemotePath.normalized(rule.remoteFolder))
        var report = SyncReport()
        let previousState = await stateStore.load(ruleID: rule.id)

        if rule.propagatesRemoteDeletes, let previousState {
            let remotePaths = Set(relativeRemoteItems(remoteItems, root: rule.remoteFolder).keys)
            let removedPaths = Set(previousState.remotePaths.filter {
                !remotePaths.contains($0) && localItems[$0] != nil
            })
            for relativePath in deletionRoots(removedPaths) {
                guard let local = localItems[relativePath] else { continue }
                try FileManager.default.removeItem(at: local.url)
                removeLocalItems(at: relativePath, from: &localItems)
                report.deletedLocal += 1
            }
        }

        if rule.propagatesLocalDeletes, let previousState {
            var remoteByRelativePath = relativeRemoteItems(remoteItems, root: rule.remoteFolder)
            let removedPaths = Set(previousState.localPaths.filter {
                !localItems.keys.contains($0) && remoteByRelativePath[$0] != nil
            })
            for relativePath in deletionRoots(removedPaths) {
                guard let remote = remoteByRelativePath[relativePath] else { continue }
                try await client.delete(remote)
                removeRemoteItems(at: relativePath, from: &remoteByRelativePath)
                report.deletedRemote += 1
            }
            remoteItems = Dictionary(uniqueKeysWithValues: remoteByRelativePath.values.map { ($0.path, $0) })
        }

        if rule.uploadsLocalChanges {
            for (relativePath, local) in localItems {
                guard !local.isDirectory else { continue }
                let remotePath = RemotePath.join(rule.remoteFolder, relativePath)
                let remote = remoteItems[remotePath]
                if shouldUpload(local: local, remote: remote, rule: rule) {
                    try await ensureRemoteDirectories(
                        for: remotePath,
                        root: rule.remoteFolder,
                        client: client,
                        knownDirectories: &knownRemoteDirectories
                    )
                    try await client.upload(local.url, to: RemotePath.parent(of: remotePath))
                    report.uploaded += 1
                } else {
                    report.skipped += 1
                }
            }
        }

        if rule.downloadsRemoteChanges {
            for (_, remote) in remoteItems where !remote.isDirectory {
                let relativePath = relativePath(for: remote.path, root: rule.remoteFolder)
                guard !relativePath.isEmpty else { continue }
                let localURL = localRoot.appending(path: relativePath)
                let local = localItems[relativePath]
                if shouldDownload(remote: remote, local: local, rule: rule) {
                    try await client.download(remote, to: localURL)
                    report.downloaded += 1
                } else {
                    report.skipped += 1
                }
            }
        }

        let finalLocalItems = try localInventory(root: localRoot)
        let finalRemoteItems = try await remoteInventory(client: client, root: rule.remoteFolder)
        let finalRemotePaths = Set(relativeRemoteItems(finalRemoteItems, root: rule.remoteFolder).keys)
        try await stateStore.save(
            SyncState(localPaths: Set(finalLocalItems.keys), remotePaths: finalRemotePaths),
            ruleID: rule.id
        )
        return report
    }

    private struct LocalItem: Sendable {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let modifiedAt: Date?
    }

    private func localInventory(root: URL) throws -> [String: LocalItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: []) else { return [:] }
        var output: [String: LocalItem] = [:]
        for case let url as URL in enumerator {
            let resolvedURL = url.resolvingSymlinksInPath()
            let values = try resolvedURL.resourceValues(forKeys: keys)
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard resolvedURL.path.hasPrefix(prefix) else { continue }
            let relative = String(resolvedURL.path.dropFirst(prefix.count))
            output[relative] = LocalItem(url: resolvedURL, isDirectory: values.isDirectory == true, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate)
        }
        return output
    }

    private func remoteInventory(client: any RemoteClient, root: String) async throws -> [String: RemoteItem] {
        var output: [String: RemoteItem] = [:]
        func visit(_ folder: String) async throws {
            for item in try await client.list(at: folder) {
                output[item.path] = item
                if item.isDirectory { try await visit(item.path) }
            }
        }
        try await visit(root)
        return output
    }

    private func ensureRemoteDirectories(
        for remotePath: String,
        root: String,
        client: any RemoteClient,
        knownDirectories: inout Set<String>
    ) async throws {
        let directory = RemotePath.parent(of: remotePath)
        guard directory != root else { return }
        var current = root
        let rootComponents = RemotePath.normalized(root).split(separator: "/").count
        let components = RemotePath.normalized(directory).split(separator: "/")
        for component in components.dropFirst(rootComponents) {
            let next = RemotePath.join(current, String(component))
            if !knownDirectories.contains(next) {
                try await createDirectoryIfNeeded(named: String(component), in: current, expectedPath: next, client: client)
                knownDirectories.insert(next)
            }
            current = next
        }
    }

    private func ensureRemoteRoot(_ root: String, client: any RemoteClient) async throws {
        let components = RemotePath.normalized(root).split(separator: "/")
        var current = "/"
        for component in components {
            let next = RemotePath.join(current, String(component))
            try await createDirectoryIfNeeded(named: String(component), in: current, expectedPath: next, client: client)
            current = next
        }
    }

    private func createDirectoryIfNeeded(
        named name: String,
        in parent: String,
        expectedPath: String,
        client: any RemoteClient
    ) async throws {
        do {
            try await client.createDirectory(named: name, in: parent)
        } catch {
            let entries = try await client.list(at: parent)
            guard entries.contains(where: { $0.path == expectedPath && $0.isDirectory }) else { throw error }
        }
    }

    private func relativePath(for fullPath: String, root: String) -> String {
        let normalizedRoot = RemotePath.normalized(root)
        let normalizedPath = RemotePath.normalized(fullPath)
        guard normalizedPath.hasPrefix(normalizedRoot + "/") else { return "" }
        return String(normalizedPath.dropFirst(normalizedRoot.count + 1))
    }

    private func relativeRemoteItems(_ items: [String: RemoteItem], root: String) -> [String: RemoteItem] {
        Dictionary(uniqueKeysWithValues: items.values.compactMap { item in
            let relative = relativePath(for: item.path, root: root)
            return relative.isEmpty ? nil : (relative, item)
        })
    }

    private func deletionRoots(_ paths: Set<String>) -> [String] {
        paths.sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }.filter { path in
            !paths.contains { candidate in candidate != path && path.hasPrefix(candidate + "/") }
        }
    }

    private func removeLocalItems(at relativePath: String, from items: inout [String: LocalItem]) {
        let prefix = relativePath + "/"
        items = items.filter { $0.key != relativePath && !$0.key.hasPrefix(prefix) }
    }

    private func removeRemoteItems(at relativePath: String, from items: inout [String: RemoteItem]) {
        let prefix = relativePath + "/"
        items = items.filter { $0.key != relativePath && !$0.key.hasPrefix(prefix) }
    }

    private func shouldUpload(local: LocalItem, remote: RemoteItem?, rule: SyncRule) -> Bool {
        guard let remote else { return true }
        switch rule.conflictDirection {
        case .uploadOnly:
            guard local.size == remote.size else { return true }
            if let localDate = local.modifiedAt, let remoteDate = remote.modifiedAt { return localDate != remoteDate }
            return false
        case .downloadOnly: return false
        case .bidirectional:
            switch rule.conflictPolicy {
            case .keepLocal: return true
            case .keepRemote: return false
            case .duplicate: return local.size != remote.size
            case .keepNewest: return (local.modifiedAt ?? .distantPast) > (remote.modifiedAt ?? .distantPast)
            }
        }
    }

    private func shouldDownload(remote: RemoteItem, local: LocalItem?, rule: SyncRule) -> Bool {
        guard let local else { return true }
        switch rule.conflictDirection {
        case .downloadOnly:
            guard remote.size == local.size else { return true }
            if let remoteDate = remote.modifiedAt, let localDate = local.modifiedAt { return remoteDate != localDate }
            return false
        case .uploadOnly: return false
        case .bidirectional:
            switch rule.conflictPolicy {
            case .keepLocal: return false
            case .keepRemote: return true
            case .duplicate: return remote.size != local.size
            case .keepNewest: return (remote.modifiedAt ?? .distantPast) > (local.modifiedAt ?? .distantPast)
            }
        }
    }
}
