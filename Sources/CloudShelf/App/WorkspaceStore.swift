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

private struct FolderDownloadPlan: Sendable {
    let root: RemoteItem
    let directories: [RemoteItem]
    let files: [RemoteItem]

    var totalBytes: Int64? {
        guard files.allSatisfy({ $0.size != nil }) else { return nil }
        return files.reduce(0) { $0 + ($1.size ?? 0) }
    }

    static func make(root: RemoteItem, client: any RemoteClient) async throws -> FolderDownloadPlan {
        var visited = Set<String>()
        var directories: [RemoteItem] = []
        var files: [RemoteItem] = []

        func visit(_ directory: RemoteItem) async throws {
            guard visited.insert(directory.path).inserted else { return }
            directories.append(directory)
            for item in try await client.list(at: directory.path) {
                if item.isDirectory {
                    try await visit(item)
                } else {
                    files.append(item)
                }
            }
        }

        try await visit(root)
        directories.sort {
            let leftDepth = $0.path.split(separator: "/").count
            let rightDepth = $1.path.split(separator: "/").count
            return leftDepth == rightDepth
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : leftDepth < rightDepth
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return FolderDownloadPlan(root: root, directories: directories, files: files)
    }

    func destinationURL(for item: RemoteItem, in destinationDirectory: URL) throws -> URL {
        let rootPath = RemotePath.normalized(root.path)
        let itemPath = RemotePath.normalized(item.path)
        let localRoot = destinationDirectory.appendingPathComponent(root.name, isDirectory: true)
        guard itemPath != rootPath else { return localRoot }
        let prefix = rootPath + "/"
        guard itemPath.hasPrefix(prefix) else {
            throw CloudShelfError.invalidResponse("远端文件夹返回了范围外的项目。")
        }
        return localRoot.appending(path: String(itemPath.dropFirst(prefix.count)))
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
    @Published private(set) var automaticSyncEnabled: Bool
    @Published private(set) var maximumConcurrentTransfers: Int
    @Published var lastError: String?

    private let profileStore = ProfileStore()
    private let syncEngine = SyncEngine()
    private var syncTimer: Timer?
    private var syncingRuleIDs = Set<UUID>()
    private var localFingerprints: [UUID: LocalFolderFingerprint] = [:]
    private var fingerprintingRuleIDs = Set<UUID>()
    private var pendingChangeSyncs: [UUID: Date] = [:]
    private typealias TransferWork = @MainActor () async -> Void
    private var transferJobs: [UUID: TransferWork] = [:]
    private var transferTargetKeys: [UUID: String] = [:]
    private var activeTransferTargetKeys = Set<String>()
    private var queuedTransferIDs: [UUID] = []
    private var runningTransferTasks: [UUID: Task<Void, Never>] = [:]
    private var pausedTransferIDs = Set<UUID>()
    private var cancelledTransferIDs = Set<UUID>()
    private var resumeAfterCancellationIDs = Set<UUID>()
    private var resumableTransferIDs = Set<UUID>()
    private var isTransferQueuePaused = false
    private static let automaticSyncEnabledKey = "CloudShelf.automaticSyncEnabled"
    private static let maximumConcurrentTransfersKey = "CloudShelf.maximumConcurrentTransfers"
    private static let automaticConnectProfileIDKey = "CloudShelf.automaticConnectProfileID"
    @Published private(set) var automaticConnectProfileID: UUID?

    init() {
        automaticSyncEnabled = UserDefaults.standard.object(forKey: Self.automaticSyncEnabledKey) as? Bool ?? true
        maximumConcurrentTransfers = Self.validConcurrentTransferCount(
            UserDefaults.standard.object(forKey: Self.maximumConcurrentTransfersKey) as? Int ?? 3
        )
        automaticConnectProfileID = UserDefaults.standard.string(forKey: Self.automaticConnectProfileIDKey).flatMap(UUID.init(uuidString:))
        Task {
            profiles = await profileStore.load().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if let id = automaticConnectProfileID, let profile = profile(id: id) {
                await mount(profile)
            } else if automaticConnectProfileID != nil {
                setAutomaticConnectProfile(nil)
            }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runScheduledSyncs() }
        }
    }

    func profile(id: UUID) -> ConnectionProfile? {
        profiles.first { $0.id == id }
    }

    func isMounted(_ id: UUID) -> Bool { sessions[id] != nil }

    func toggleAutomaticSync() {
        automaticSyncEnabled.toggle()
        UserDefaults.standard.set(automaticSyncEnabled, forKey: Self.automaticSyncEnabledKey)
        if !automaticSyncEnabled { pendingChangeSyncs.removeAll() }
    }

    func setMaximumConcurrentTransfers(_ count: Int) {
        maximumConcurrentTransfers = Self.validConcurrentTransferCount(count)
        UserDefaults.standard.set(maximumConcurrentTransfers, forKey: Self.maximumConcurrentTransfersKey)
        startQueuedTransfers()
    }

    func setAutomaticConnectProfile(_ id: UUID?) {
        automaticConnectProfileID = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: Self.automaticConnectProfileIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.automaticConnectProfileIDKey)
        }
    }

    func pauseTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        switch transfers[index].status {
        case .queued:
            resumeAfterCancellationIDs.remove(id)
            queuedTransferIDs.removeAll { $0 == id }
            pausedTransferIDs.insert(id)
            updateTransfer(id, status: .paused, detail: "已暂停，等待继续")
        case .running:
            resumeAfterCancellationIDs.remove(id)
            pausedTransferIDs.insert(id)
            resumableTransferIDs.insert(id)
            updateTransfer(id, status: .paused, detail: "正在暂停…")
            runningTransferTasks[id]?.cancel()
        case .paused:
            resumeAfterCancellationIDs.remove(id)
            pausedTransferIDs.insert(id)
            runningTransferTasks[id]?.cancel()
        case .succeeded, .failed, .cancelled:
            return
        }
    }

    func cancelTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].status == .paused else { return }
        queuedTransferIDs.removeAll { $0 == id }
        pausedTransferIDs.remove(id)
        resumeAfterCancellationIDs.remove(id)
        resumableTransferIDs.remove(id)
        cancelledTransferIDs.insert(id)
        updateTransfer(id, status: .cancelled, detail: "已取消", finishedAt: .now)
        runningTransferTasks[id]?.cancel()
    }

    func resumeTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].status == .paused,
              transferJobs[id] != nil else { return }

        // A process can take a moment to acknowledge cancellation. Preserve an
        // immediate Continue click and enqueue it only after that process exits.
        if runningTransferTasks[id] != nil {
            guard resumeAfterCancellationIDs.insert(id).inserted else { return }
            pausedTransferIDs.remove(id)
            updateTransfer(id, status: .paused, detail: "正在停止，随后继续")
            return
        }

        pausedTransferIDs.remove(id)
        updateTransfer(id, status: .queued, detail: "等待继续")
        enqueueTransferID(id)
        startQueuedTransfers()
    }

    func retryTransfer(_ id: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == id }),
              transfers[index].status == .failed,
              transferJobs[id] != nil else { return }
        pausedTransferIDs.remove(id)
        resumeAfterCancellationIDs.remove(id)
        transfers[index].startedAt = nil
        transfers[index].finishedAt = nil
        transfers[index].bytesPerSecond = nil
        updateTransfer(id, status: .queued, detail: "等待重试", finishedAt: nil)
        enqueueTransferID(id)
        startQueuedTransfers()
    }

    func startAllTransfers() {
        isTransferQueuePaused = false
        for transfer in transfers where transfer.status == .paused {
            resumeTransfer(transfer.id)
        }
        startQueuedTransfers()
    }

    func pauseAllTransfers() {
        isTransferQueuePaused = true
        let activeIDs = transfers.filter { $0.status == .queued || $0.status == .running }.map(\.id)
        activeIDs.forEach(pauseTransfer)
    }

    func retryFailedTransfers() {
        transfers.filter { $0.status == .failed }.forEach { retryTransfer($0.id) }
    }

    func clearFinishedTransfers() {
        let removable = Set(transfers.filter { $0.status == .succeeded || $0.status == .failed || $0.status == .cancelled }.map(\.id))
        transfers.removeAll { removable.contains($0.id) }
        removable.forEach {
            transferJobs.removeValue(forKey: $0)
            if let targetKey = transferTargetKeys.removeValue(forKey: $0) {
                activeTransferTargetKeys.remove(targetKey)
            }
            resumableTransferIDs.remove($0)
            pausedTransferIDs.remove($0)
            resumeAfterCancellationIDs.remove($0)
            cancelledTransferIDs.remove($0)
        }
    }

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
        if automaticConnectProfileID == profile.id { setAutomaticConnectProfile(nil) }
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
        enqueueTransfer(transfer, targetKey: "sync:\(profile.id.uuidString):\(rule.id.uuidString)") { [weak self] in
            await self?.performSync(transferID: transfer.id, profile: profile, rule: rule, session: session)
        }
    }

    private func performSync(transferID: UUID, profile: ConnectionProfile, rule: SyncRule, session: RemoteSession) async {
        defer { syncingRuleIDs.remove(rule.id) }
        updateTransfer(transferID, status: .running, detail: "正在比较文件夹", startedAt: .now)
        do {
            try Task.checkCancellation()
            let report = try await syncEngine.synchronize(rule: rule, client: session.client)
            try Task.checkCancellation()
            let deletions = report.deletedRemote + report.deletedLocal
            let deletionText = deletions == 0 ? "" : "，已删除远端 \(report.deletedRemote) 项、本地 \(report.deletedLocal) 项"
            updateTransfer(transferID, status: .succeeded, detail: "已上传 \(report.uploaded) 项，已下载 \(report.downloaded) 项\(deletionText)", finishedAt: .now)
            markSynced(ruleID: rule.id, profileID: profile.id)
            clearChangeTracking(for: rule.id)
        } catch {
            guard !markTransferPausedIfCancelled(transferID) else { return }
            updateTransfer(transferID, status: .failed, detail: error.localizedDescription, finishedAt: .now)
            lastError = error.localizedDescription
        }
        await session.reload()
    }

    private func enqueueTransfer(_ transfer: TransferTask, targetKey: String? = nil, work: @escaping TransferWork) {
        transfers.append(transfer)
        transferJobs[transfer.id] = work
        if let targetKey { transferTargetKeys[transfer.id] = targetKey }
        enqueueTransferID(transfer.id)
        startQueuedTransfers()
    }

    private func enqueueTransferID(_ id: UUID) {
        guard !queuedTransferIDs.contains(id) else { return }
        queuedTransferIDs.append(id)
    }

    private func startQueuedTransfers() {
        guard !isTransferQueuePaused else { return }
        var inspected = 0
        while runningTransferTasks.count < maximumConcurrentTransfers,
              !queuedTransferIDs.isEmpty,
              inspected < queuedTransferIDs.count {
            let id = queuedTransferIDs.removeFirst()
            inspected += 1
            if let targetKey = transferTargetKeys[id], activeTransferTargetKeys.contains(targetKey) {
                queuedTransferIDs.append(id)
                continue
            }
            guard let index = transfers.firstIndex(where: { $0.id == id }),
                  transfers[index].status == .queued,
                  let work = transferJobs[id] else { continue }
            if let targetKey = transferTargetKeys[id] { activeTransferTargetKeys.insert(targetKey) }
            let task = Task { [weak self] in
                await work()
                guard let self else { return }
                self.finishTransferExecution(id)
            }
            runningTransferTasks[id] = task
        }
    }

    private func finishTransferExecution(_ id: UUID) {
        runningTransferTasks.removeValue(forKey: id)
        if let targetKey = transferTargetKeys[id] { activeTransferTargetKeys.remove(targetKey) }
        if resumeAfterCancellationIDs.remove(id) != nil,
           let index = transfers.firstIndex(where: { $0.id == id }),
           transfers[index].status == .paused {
            pausedTransferIDs.remove(id)
            updateTransfer(id, status: .queued, detail: "等待继续")
            enqueueTransferID(id)
        }
        startQueuedTransfers()
    }

    private func markTransferPausedIfCancelled(_ id: UUID) -> Bool {
        if cancelledTransferIDs.contains(id) {
            updateTransfer(id, status: .cancelled, detail: "已取消", finishedAt: .now)
            return true
        }
        guard Task.isCancelled || pausedTransferIDs.contains(id) else { return false }
        pausedTransferIDs.insert(id)
        resumableTransferIDs.insert(id)
        updateTransfer(id, status: .paused, detail: "已暂停，可继续", finishedAt: nil)
        return true
    }

    private static func validConcurrentTransferCount(_ count: Int) -> Int {
        min(max(count, 1), 8)
    }

    private func enqueueUpload(_ url: URL, session: RemoteSession) {
        let destination = session.location
        let transfer = TransferTask(direction: .upload, title: url.lastPathComponent, connectionName: session.profile.name)
        enqueueTransfer(
            transfer,
            targetKey: "remote:\(session.profile.id.uuidString):\(RemotePath.join(destination, url.lastPathComponent))"
        ) { [weak self] in
            await self?.performUpload(transferID: transfer.id, url: url, destination: destination, session: session)
        }
    }

    private func performUpload(transferID: UUID, url: URL, destination: String, session: RemoteSession) async {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                updateTransfer(transferID, status: .running, detail: "正在准备文件夹", startedAt: .now)
                let plan = try await Task.detached(priority: .userInitiated) {
                    try FolderUploadPlan.make(source: url, remoteParent: destination)
                }.value
                try Task.checkCancellation()
                setTransferTotal(transferID, bytes: plan.files.reduce(0) { $0 + $1.size })
                try await upload(folder: plan, client: session.client, transferID: transferID)
                let skipped = plan.skippedItems == 0 ? "" : "，跳过 \(plan.skippedItems) 项"
                updateTransfer(
                    transferID,
                    status: .succeeded,
                    detail: "已上传 \(plan.files.count) 个文件，创建 \(plan.directories.count) 个文件夹\(skipped)",
                    finishedAt: .now,
                    completedBytes: plan.files.reduce(0) { $0 + $1.size }
                )
            } else {
                let size = Int64(values.fileSize ?? 0)
                setTransferTotal(transferID, bytes: size)
                let supportsResume = await session.client.supportsResumableTransfers()
                let offset = supportsResume && resumableTransferIDs.contains(transferID)
                    ? await remoteResumeOffset(for: url.lastPathComponent, in: destination, client: session.client, maximum: size)
                    : 0
                if offset == size, size > 0 {
                    updateTransfer(transferID, status: .succeeded, detail: "远端已有完整文件", finishedAt: .now, completedBytes: size)
                    return
                }
                let detail = offset > 0 ? "从 \(ByteCountFormatter.string(fromByteCount: offset, countStyle: .file)) 继续上传" : "正在上传"
                updateTransfer(transferID, status: .running, detail: detail, startedAt: .now, completedBytes: offset)
                try await session.client.upload(
                    url,
                    to: destination,
                    resumeFrom: offset,
                    progress: transferProgressHandler(for: transferID, offset: offset, totalBytes: size)
                )
                try Task.checkCancellation()
                updateTransfer(transferID, status: .succeeded, detail: "上传完成", finishedAt: .now, completedBytes: size)
            }
            await session.reload()
        } catch {
            guard !markTransferPausedIfCancelled(transferID) else { return }
            updateTransfer(transferID, status: .failed, detail: error.localizedDescription, finishedAt: .now)
            lastError = error.localizedDescription
        }
    }

    private func upload(
        folder plan: FolderUploadPlan,
        client: any RemoteClient,
        transferID: UUID
    ) async throws {
        for (index, path) in plan.directories.enumerated() {
            try Task.checkCancellation()
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
            try Task.checkCancellation()
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
            try Task.checkCancellation()
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
            totalBytes: item.isDirectory ? nil : item.size
        )
        enqueueTransfer(
            transfer,
            targetKey: "local:\(directory.standardizedFileURL.path)/\(item.name)"
        ) { [weak self] in
            await self?.performDownload(transferID: transfer.id, item: item, directory: directory, session: session)
        }
    }

    private func performDownload(transferID: UUID, item: RemoteItem, directory: URL, session: RemoteSession) async {
        do {
            if item.isDirectory {
                updateTransfer(transferID, status: .running, detail: "正在读取远端文件夹", startedAt: .now)
                let plan = try await FolderDownloadPlan.make(root: item, client: session.client)
                try Task.checkCancellation()
                if let totalBytes = plan.totalBytes { setTransferTotal(transferID, bytes: totalBytes) }
                let completedBytes = try await download(folder: plan, to: directory, client: session.client, transferID: transferID)
                updateTransfer(
                    transferID,
                    status: .succeeded,
                    detail: "已下载 \(plan.files.count) 个文件，创建 \(plan.directories.count) 个文件夹",
                    finishedAt: .now,
                    completedBytes: completedBytes
                )
            } else {
                let destination = directory.appendingPathComponent(item.name)
                let partial = directory.appendingPathComponent(".\(item.name).\(transferID.uuidString).cloudshelf-part")
                let supportsResume = await session.client.supportsResumableTransfers()
                let canResume = supportsResume && resumableTransferIDs.contains(transferID)
                let resumeOffset = canResume ? localResumeOffset(at: partial, maximum: item.size) : 0
                if resumeOffset == 0, FileManager.default.fileExists(atPath: partial.path) {
                    try FileManager.default.removeItem(at: partial)
                }
                try Task.checkCancellation()
                if let size = item.size, resumeOffset == size, size > 0 {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: partial, to: destination)
                    resumableTransferIDs.remove(transferID)
                    updateTransfer(transferID, status: .succeeded, detail: "已完成续传", finishedAt: .now, completedBytes: size)
                    return
                }
                let detail = resumeOffset > 0 ? "从 \(ByteCountFormatter.string(fromByteCount: resumeOffset, countStyle: .file)) 继续下载" : "正在下载"
                updateTransfer(transferID, status: .running, detail: detail, startedAt: .now, completedBytes: resumeOffset)
                try await session.client.download(
                    item,
                    to: partial,
                    resumeFrom: resumeOffset,
                    progress: transferProgressHandler(for: transferID, offset: resumeOffset, totalBytes: item.size)
                )
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: partial, to: destination)
                resumableTransferIDs.remove(transferID)
                updateTransfer(transferID, status: .succeeded, detail: "下载完成", finishedAt: .now, completedBytes: item.size ?? 0)
            }
        } catch {
            guard !markTransferPausedIfCancelled(transferID) else { return }
            updateTransfer(transferID, status: .failed, detail: error.localizedDescription, finishedAt: .now)
            lastError = error.localizedDescription
        }
    }

    private func download(
        folder plan: FolderDownloadPlan,
        to destinationDirectory: URL,
        client: any RemoteClient,
        transferID: UUID
    ) async throws -> Int64 {
        for (index, remoteDirectory) in plan.directories.enumerated() {
            try Task.checkCancellation()
            updateTransfer(
                transferID,
                status: .running,
                detail: "正在创建本地文件夹 \(index + 1)/\(plan.directories.count)"
            )
            try FileManager.default.createDirectory(
                at: try plan.destinationURL(for: remoteDirectory, in: destinationDirectory),
                withIntermediateDirectories: true
            )
        }

        var completedBytes: Int64 = 0
        for (index, remoteFile) in plan.files.enumerated() {
            try Task.checkCancellation()
            updateTransfer(
                transferID,
                status: .running,
                detail: "正在下载文件 \(index + 1)/\(plan.files.count)"
            )
            try await client.download(
                remoteFile,
                to: try plan.destinationURL(for: remoteFile, in: destinationDirectory),
                progress: transferProgressHandler(
                    for: transferID,
                    offset: completedBytes,
                    totalBytes: plan.totalBytes,
                    useReportedTotal: plan.totalBytes != nil
                )
            )
            try Task.checkCancellation()
            completedBytes += remoteFile.size ?? 0
            updateTransfer(
                transferID,
                status: .running,
                detail: "正在下载文件 \(index + 1)/\(plan.files.count)",
                completedBytes: completedBytes
            )
        }
        return completedBytes
    }

    private func enqueueCopy(_ item: RemoteItem, destination: String, session: RemoteSession) {
        let transfer = TransferTask(direction: .sync, title: "复制 \(item.name)", connectionName: session.profile.name)
        enqueueTransfer(
            transfer,
            targetKey: "remote:\(session.profile.id.uuidString):\(RemotePath.join(destination, item.name))"
        ) { [weak self] in
            await self?.performRemoteOperation(transferID: transfer.id, detail: "正在复制", success: "复制完成", session: session) {
                try await session.client.copy(item, to: destination)
            }
        }
    }

    private func enqueueMove(_ item: RemoteItem, destination: String, session: RemoteSession) {
        let transfer = TransferTask(direction: .sync, title: "移动 \(item.name)", connectionName: session.profile.name)
        enqueueTransfer(
            transfer,
            targetKey: "remote:\(session.profile.id.uuidString):\(RemotePath.join(destination, item.name))"
        ) { [weak self] in
            await self?.performRemoteOperation(transferID: transfer.id, detail: "正在移动", success: "移动完成", session: session) {
                try await session.client.move(item, to: destination)
            }
        }
    }

    private func performRemoteOperation(
        transferID: UUID,
        detail: String,
        success: String,
        session: RemoteSession,
        operation: @escaping () async throws -> Void
    ) async {
        updateTransfer(transferID, status: .running, detail: detail, startedAt: .now)
        do {
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
            updateTransfer(transferID, status: .succeeded, detail: success, finishedAt: .now)
            await session.reload()
        } catch {
            guard !markTransferPausedIfCancelled(transferID) else { return }
            updateTransfer(transferID, status: .failed, detail: error.localizedDescription, finishedAt: .now)
            lastError = error.localizedDescription
        }
    }

    private func localResumeOffset(at url: URL, maximum: Int64?) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let maximum, size > maximum { return 0 }
        return size
    }

    private func remoteResumeOffset(
        for name: String,
        in directory: String,
        client: any RemoteClient,
        maximum: Int64
    ) async -> Int64 {
        guard let items = try? await client.list(at: directory),
              let existing = items.first(where: { !$0.isDirectory && $0.name == name }),
              let size = existing.size else { return 0 }
        return min(size, maximum)
    }

    private func setTransferTotal(_ id: UUID, bytes: Int64) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].totalBytes = max(0, bytes)
        transfers[index].completedBytes = min(transfers[index].completedBytes, transfers[index].totalBytes ?? 0)
    }

    private func transferProgressHandler(
        for transferID: UUID,
        offset: Int64 = 0,
        totalBytes: Int64?,
        useReportedTotal: Bool = true
    ) -> TransferProgressHandler {
        { [weak self] completedBytes, reportedTotalBytes in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let total = totalBytes ?? (useReportedTotal ? reportedTotalBytes.map { offset + $0 } : nil)
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
        if let totalBytes { transfers[index].totalBytes = max(0, totalBytes) }
        if let completedBytes {
            let completed = max(0, completedBytes)
            transfers[index].completedBytes = transfers[index].totalBytes.map { min(completed, $0) } ?? completed
        } else if let total = transfers[index].totalBytes {
            transfers[index].completedBytes = min(transfers[index].completedBytes, total)
        }
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
        guard automaticSyncEnabled else { return }
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
