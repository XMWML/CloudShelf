import AppKit
import Combine
import Foundation
import CloudShelfCore

@MainActor
final class RemoteSession: ObservableObject, Identifiable {
    let profile: ConnectionProfile
    let client: any RemoteClient
    let id: UUID

    @Published private(set) var location: String = "/"
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    private var history = ["/"]
    private var historyIndex = 0

    init(profile: ConnectionProfile, client: any RemoteClient) {
        self.profile = profile
        self.client = client
        self.id = profile.id
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await client.list(at: location)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ item: RemoteItem) async {
        guard item.isDirectory else { return }
        location = item.path
        if historyIndex < history.count - 1 { history.removeLast(history.count - historyIndex - 1) }
        history.append(location)
        historyIndex = history.count - 1
        updateHistoryState()
        await reload()
    }

    func goUp() async {
        guard location != "/" else { return }
        await openPath(RemotePath.parent(of: location), addToHistory: true)
    }

    func goBack() async {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        location = history[historyIndex]
        updateHistoryState()
        await reload()
    }

    func goForward() async {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1
        location = history[historyIndex]
        updateHistoryState()
        await reload()
    }

    func openPath(_ path: String, addToHistory: Bool = true) async {
        location = RemotePath.normalized(path)
        if addToHistory {
            if historyIndex < history.count - 1 { history.removeLast(history.count - historyIndex - 1) }
            history.append(location)
            historyIndex = history.count - 1
        }
        updateHistoryState()
        await reload()
    }

    private func updateHistoryState() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex + 1 < history.count
    }
}

private struct FolderUploadPlan: Sendable {
    struct File: Sendable {
        let url: URL
        let remotePath: String
        let size: Int64
    }

    let directories: [String]
    let files: [File]
    let skippedItems: Int

    static func make(source: URL, remoteParent: String) throws -> FolderUploadPlan {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let root = source.standardizedFileURL
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true else {
            throw CloudShelfError.invalidProfile("选择的项目不是文件夹。")
        }
        guard !root.lastPathComponent.isEmpty else {
            throw CloudShelfError.invalidProfile("无法确定文件夹名称。")
        }

        let remoteRoot = RemotePath.join(remoteParent, root.lastPathComponent)
        let rootComponents = root.pathComponents
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw CloudShelfError.commandFailed("无法读取本地文件夹。")
        }

        var directories = [remoteRoot]
        var files: [File] = []
        var skippedItems = 0
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: keys)
            let components = child.standardizedFileURL.pathComponents.dropFirst(rootComponents.count)
            guard !components.isEmpty else { continue }
            let remotePath = components.reduce(remoteRoot) { RemotePath.join($0, $1) }

            if values.isSymbolicLink == true {
                skippedItems += 1
            } else if values.isDirectory == true {
                directories.append(remotePath)
            } else if values.isRegularFile == true {
                files.append(File(url: child, remotePath: remotePath, size: Int64(values.fileSize ?? 0)))
            } else {
                skippedItems += 1
            }
        }

        directories.sort {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            return leftDepth == rightDepth
                ? $0.localizedStandardCompare($1) == .orderedAscending
                : leftDepth < rightDepth
        }
        files.sort { $0.remotePath.localizedStandardCompare($1.remotePath) == .orderedAscending }
        return FolderUploadPlan(directories: directories, files: files, skippedItems: skippedItems)
    }
}

private struct LocalFolderFingerprint: Sendable, Equatable {
    let itemCount: Int
    let totalBytes: Int64
    let signature: UInt64

    static func make(folder: String) throws -> LocalFolderFingerprint {
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CloudShelfError.invalidProfile("本地同步文件夹不存在。")
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw CloudShelfError.commandFailed("无法检查本地同步文件夹。")
        }

        var itemCount = 0
        var totalBytes: Int64 = 0
        var signature: UInt64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            let relativePath = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let size = Int64(values.fileSize ?? 0)
            let modified = Int64((values.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1_000)
            let kind = values.isDirectory == true ? "d" : "f"
            signature ^= stableHash("\(relativePath)|\(kind)|\(size)|\(modified)")
            itemCount += 1
            if values.isDirectory != true { totalBytes += size }
        }
        return LocalFolderFingerprint(itemCount: itemCount, totalBytes: totalBytes, signature: signature)
    }

    private static func stableHash(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var sessions: [UUID: RemoteSession] = [:]
    @Published private(set) var transfers: [TransferTask] = []
    @Published var lastError: String?

    private let profileStore = ProfileStore()
    private let syncEngine = SyncEngine()
    private var syncTimer: Timer?
    private var syncingRuleIDs = Set<UUID>()
    private var localFingerprints: [UUID: LocalFolderFingerprint] = [:]
    private var fingerprintingRuleIDs = Set<UUID>()
    private var pendingChangeSyncs: [UUID: Date] = [:]

    init() {
        Task {
            profiles = await profileStore.load().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runScheduledSyncs() }
        }
    }

    func profile(id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    func isMounted(_ id: UUID) -> Bool { sessions[id] != nil }

    func save(profile: ConnectionProfile, secret: String?) async {
        do {
            if let secret, !secret.isEmpty { try CredentialStore.save(secret: secret, profileID: profile.id) }
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            try await profileStore.save(profiles)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func replaceSyncRules(_ rules: [SyncRule], for profileID: UUID) async {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let previousRules = profiles[index].syncRules
        let previousRuleIDs = Set(previousRules.map(\.id))
        let updatedRuleIDs = Set(rules.map(\.id))
        profiles[index].syncRules = rules
        for ruleID in previousRuleIDs.subtracting(updatedRuleIDs) {
            clearChangeTracking(for: ruleID)
            await syncEngine.removeState(for: ruleID)
        }
        for rule in rules {
            guard let previous = previousRules.first(where: { $0.id == rule.id }),
                  previous.localFolder != rule.localFolder || previous.remoteFolder != rule.remoteFolder else { continue }
            clearChangeTracking(for: rule.id)
            await syncEngine.removeState(for: rule.id)
        }
        do {
            try await profileStore.save(profiles)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(profile: ConnectionProfile) async {
        sessions.removeValue(forKey: profile.id)
        profiles.removeAll { $0.id == profile.id }
        CredentialStore.delete(profileID: profile.id)
        profile.syncRules.forEach { rule in
            clearChangeTracking(for: rule.id)
            Task { await syncEngine.removeState(for: rule.id) }
        }
        do { try await profileStore.save(profiles) } catch { lastError = error.localizedDescription }
    }

    func mount(_ profile: ConnectionProfile) async {
        guard sessions[profile.id] == nil else { return }
        LocalNetworkAccessRequester.shared.requestAccess(for: profile)
        do {
            let session = RemoteSession(profile: profile, client: try RemoteClientFactory.make(profile: profile))
            sessions[profile.id] = session
            await session.reload()
            if let message = session.errorMessage { lastError = message }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unmount(_ profile: ConnectionProfile) {
        sessions.removeValue(forKey: profile.id)
    }

    func createFolder(_ name: String, in session: RemoteSession) async {
        do {
            try await session.client.createDirectory(named: name, in: session.location)
            await session.reload()
        } catch { lastError = error.localizedDescription }
    }

    func rename(_ item: RemoteItem, to name: String, in session: RemoteSession) async {
        do {
            try await session.client.rename(item, to: name)
            await session.reload()
        } catch { lastError = error.localizedDescription }
    }

    func delete(_ items: [RemoteItem], in session: RemoteSession) async {
        do {
            for item in items { try await session.client.delete(item) }
            await session.reload()
        } catch { lastError = error.localizedDescription }
    }

    func upload(_ urls: [URL], to session: RemoteSession) {
        for url in urls { enqueueUpload(url, session: session) }
    }

    func download(_ items: [RemoteItem], to directory: URL, from session: RemoteSession) {
        for item in items { enqueueDownload(item, directory: directory, session: session) }
    }

    func copy(_ items: [RemoteItem], to directory: String, from session: RemoteSession) {
        for item in items { enqueueCopy(item, destination: directory, session: session) }
    }

    func move(_ items: [RemoteItem], to directory: String, from session: RemoteSession) {
        for item in items { enqueueMove(item, destination: directory, session: session) }
    }

    func sync(profile: ConnectionProfile, rule: SyncRule) {
        guard let session = sessions[profile.id] else {
            lastError = "请先连接 \(profile.name)，再执行同步规则。"
            return
        }
        guard syncingRuleIDs.insert(rule.id).inserted else { return }
        let transfer = TransferTask(direction: .sync, title: "同步 \(URL(fileURLWithPath: rule.localFolder).lastPathComponent)", connectionName: profile.name)
        transfers.append(transfer)
        Task {
            defer { syncingRuleIDs.remove(rule.id) }
            updateTransfer(transfer.id, status: .running, detail: "正在比较文件夹", startedAt: .now)
            do {
                let report = try await syncEngine.synchronize(rule: rule, client: session.client)
                let deletions = report.deletedRemote + report.deletedLocal
                let deletionText = deletions == 0 ? "" : "，已删除远端 \(report.deletedRemote) 项、本地 \(report.deletedLocal) 项"
                updateTransfer(transfer.id, status: .succeeded, detail: "已上传 \(report.uploaded) 项，已下载 \(report.downloaded) 项\(deletionText)", finishedAt: .now)
                markSynced(ruleID: rule.id, profileID: profile.id)
                clearChangeTracking(for: rule.id)
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
            await session.reload()
        }
    }

    private func enqueueUpload(_ url: URL, session: RemoteSession) {
        let destination = session.location
        let transfer = TransferTask(direction: .upload, title: url.lastPathComponent, connectionName: session.profile.name)
        transfers.append(transfer)
        Task {
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values.isDirectory == true {
                    updateTransfer(transfer.id, status: .running, detail: "正在准备文件夹", startedAt: .now)
                    let plan = try await Task.detached(priority: .userInitiated) {
                        try FolderUploadPlan.make(source: url, remoteParent: destination)
                    }.value
                    setTransferTotal(transfer.id, bytes: plan.files.reduce(0) { $0 + $1.size })
                    try await upload(folder: plan, client: session.client, transferID: transfer.id)
                    let skipped = plan.skippedItems == 0 ? "" : "，跳过 \(plan.skippedItems) 项"
                    updateTransfer(
                        transfer.id,
                        status: .succeeded,
                        detail: "已上传 \(plan.files.count) 个文件，创建 \(plan.directories.count) 个文件夹\(skipped)",
                        finishedAt: .now,
                        completedBytes: plan.files.reduce(0) { $0 + $1.size }
                    )
                } else {
                    let size = Int64(values.fileSize ?? 0)
                    setTransferTotal(transfer.id, bytes: size)
                    updateTransfer(transfer.id, status: .running, detail: "正在上传", startedAt: .now)
                    try await session.client.upload(
                        url,
                        to: destination,
                        progress: transferProgressHandler(for: transfer.id, totalBytes: size)
                    )
                    updateTransfer(
                        transfer.id,
                        status: .succeeded,
                        detail: "上传完成",
                        finishedAt: .now,
                        completedBytes: size
                    )
                }
                await session.reload()
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
        }
    }

    private func upload(
        folder plan: FolderUploadPlan,
        client: any RemoteClient,
        transferID: UUID
    ) async throws {
        for (index, path) in plan.directories.enumerated() {
            updateTransfer(
                transferID,
                status: .running,
                detail: "正在创建文件夹 \(index + 1)/\(plan.directories.count)"
            )
            try await ensureRemoteDirectory(path, client: client)
        }

        let totalBytes = plan.files.reduce(0) { $0 + $1.size }
        var completedBytes: Int64 = 0
        for (index, file) in plan.files.enumerated() {
            updateTransfer(
                transferID,
                status: .running,
                detail: "正在上传文件 \(index + 1)/\(plan.files.count)"
            )
            try await client.upload(
                file.url,
                to: RemotePath.parent(of: file.remotePath),
                progress: transferProgressHandler(for: transferID, offset: completedBytes, totalBytes: totalBytes)
            )
            completedBytes += file.size
            updateTransfer(
                transferID,
                status: .running,
                detail: "正在上传文件 \(index + 1)/\(plan.files.count)",
                completedBytes: completedBytes
            )
        }
    }

    private func ensureRemoteDirectory(_ path: String, client: any RemoteClient) async throws {
        let parent = RemotePath.parent(of: path)
        let name = RemotePath.name(of: path)
        do {
            try await client.createDirectory(named: name, in: parent)
        } catch {
            let entries = try await client.list(at: parent)
            guard entries.contains(where: { $0.path == path && $0.isDirectory }) else { throw error }
        }
    }

    private func enqueueDownload(_ item: RemoteItem, directory: URL, session: RemoteSession) {
        let transfer = TransferTask(
            direction: .download,
            title: item.name,
            connectionName: session.profile.name,
            totalBytes: item.size
        )
        transfers.append(transfer)
        Task {
            updateTransfer(transfer.id, status: .running, detail: "正在下载", startedAt: .now)
            do {
                try await session.client.download(
                    item,
                    to: directory.appendingPathComponent(item.name),
                    progress: transferProgressHandler(for: transfer.id, totalBytes: item.size)
                )
                updateTransfer(
                    transfer.id,
                    status: .succeeded,
                    detail: "下载完成",
                    finishedAt: .now,
                    completedBytes: item.size ?? 0
                )
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
        }
    }

    private func enqueueCopy(_ item: RemoteItem, destination: String, session: RemoteSession) {
        let transfer = TransferTask(direction: .sync, title: "复制 \(item.name)", connectionName: session.profile.name)
        transfers.append(transfer)
        Task {
            updateTransfer(transfer.id, status: .running, detail: "正在复制", startedAt: .now)
            do {
                try await session.client.copy(item, to: destination)
                updateTransfer(transfer.id, status: .succeeded, detail: "复制完成", finishedAt: .now)
                await session.reload()
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
        }
    }

    private func enqueueMove(_ item: RemoteItem, destination: String, session: RemoteSession) {
        let transfer = TransferTask(direction: .sync, title: "移动 \(item.name)", connectionName: session.profile.name)
        transfers.append(transfer)
        Task {
            updateTransfer(transfer.id, status: .running, detail: "正在移动", startedAt: .now)
            do {
                try await session.client.move(item, to: destination)
                updateTransfer(transfer.id, status: .succeeded, detail: "移动完成", finishedAt: .now)
                await session.reload()
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
        }
    }

    private func setTransferTotal(_ id: UUID, bytes: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].totalBytes = bytes
    }

    private func transferProgressHandler(
        for transferID: UUID,
        offset: Int64 = 0,
        totalBytes: Int64?
    ) -> TransferProgressHandler {
        { [weak self] completedBytes, reportedTotalBytes in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let total = totalBytes ?? reportedTotalBytes.map { offset + $0 }
                self.recordTransferProgress(transferID, completedBytes: offset + completedBytes, totalBytes: total)
            }
        }
    }

    private func recordTransferProgress(_ id: UUID, completedBytes: Int64, totalBytes: Int64?) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        updateTransfer(
            id,
            status: transfers[index].status,
            detail: transfers[index].detail,
            completedBytes: completedBytes,
            totalBytes: totalBytes
        )
    }

    private func updateTransfer(
        _ id: UUID,
        status: TransferStatus,
        detail: String,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil
    ) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].status = status
        transfers[index].detail = detail
        if let startedAt { transfers[index].startedAt = startedAt }
        if let finishedAt { transfers[index].finishedAt = finishedAt }
        if let completedBytes { transfers[index].completedBytes = completedBytes }
        if let totalBytes { transfers[index].totalBytes = totalBytes }
        let elapsed = (finishedAt ?? .now).timeIntervalSince(transfers[index].startedAt ?? .now)
        if transfers[index].completedBytes > 0, elapsed > 0 {
            transfers[index].bytesPerSecond = Double(transfers[index].completedBytes) / elapsed
        }
    }

    private func markSynced(ruleID: UUID, profileID: UUID) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }), let ruleIndex = profiles[profileIndex].syncRules.firstIndex(where: { $0.id == ruleID }) else { return }
        profiles[profileIndex].syncRules[ruleIndex].lastSyncedAt = .now
        Task { try? await profileStore.save(profiles) }
    }

    private func runScheduledSyncs() {
        let now = Date.now
        detectLocalFolderChanges()
        for profile in profiles where sessions[profile.id] != nil {
            for rule in profile.syncRules where rule.isEnabled {
                if let requestedAt = pendingChangeSyncs[rule.id], requestedAt <= now {
                    pendingChangeSyncs.removeValue(forKey: rule.id)
                    sync(profile: profile, rule: rule)
                }
                let dueDate = rule.lastSyncedAt?.addingTimeInterval(Double(rule.intervalMinutes * 60)) ?? .distantPast
                if now >= dueDate { sync(profile: profile, rule: rule) }
            }
        }
    }

    private func detectLocalFolderChanges() {
        for profile in profiles where sessions[profile.id] != nil {
            for rule in profile.syncRules where rule.isEnabled && rule.syncOnLocalChanges == true && rule.observesLocalChanges {
                guard fingerprintingRuleIDs.insert(rule.id).inserted else { continue }
                Task { [weak self] in
                    let fingerprint = try? await Task.detached(priority: .utility) {
                        try LocalFolderFingerprint.make(folder: rule.localFolder)
                    }.value
                    guard let self else { return }
                    self.fingerprintingRuleIDs.remove(rule.id)
                    guard let fingerprint else { return }
                    if let previous = self.localFingerprints[rule.id], previous != fingerprint {
                        self.pendingChangeSyncs[rule.id] = .now.addingTimeInterval(2)
                    }
                    self.localFingerprints[rule.id] = fingerprint
                }
            }
        }
    }

    private func clearChangeTracking(for ruleID: UUID) {
        localFingerprints.removeValue(forKey: ruleID)
        pendingChangeSyncs.removeValue(forKey: ruleID)
    }
}
