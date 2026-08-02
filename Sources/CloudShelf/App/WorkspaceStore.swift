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

    init() {
        Task {
            profiles = await profileStore.load().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runDueSyncs() }
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

    func delete(profile: ConnectionProfile) async {
        sessions.removeValue(forKey: profile.id)
        profiles.removeAll { $0.id == profile.id }
        CredentialStore.delete(profileID: profile.id)
        do { try await profileStore.save(profiles) } catch { lastError = error.localizedDescription }
    }

    func mount(_ profile: ConnectionProfile) async {
        guard sessions[profile.id] == nil else { return }
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
            lastError = "Connect \(profile.name) before running its sync rules."
            return
        }
        guard syncingRuleIDs.insert(rule.id).inserted else { return }
        let transfer = TransferTask(direction: .sync, title: "Sync \(URL(fileURLWithPath: rule.localFolder).lastPathComponent)", connectionName: profile.name)
        transfers.append(transfer)
        Task {
            defer { syncingRuleIDs.remove(rule.id) }
            updateTransfer(transfer.id, status: .running, detail: "Comparing folders", startedAt: .now)
            do {
                let report = try await syncEngine.synchronize(rule: rule, client: session.client)
                updateTransfer(transfer.id, status: .succeeded, detail: "\(report.uploaded) uploaded, \(report.downloaded) downloaded", finishedAt: .now)
                markSynced(ruleID: rule.id, profileID: profile.id)
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
            await session.reload()
        }
    }

    private func enqueueUpload(_ url: URL, session: RemoteSession) {
        let transfer = TransferTask(direction: .upload, title: url.lastPathComponent, connectionName: session.profile.name)
        transfers.append(transfer)
        Task {
            updateTransfer(transfer.id, status: .running, detail: "Uploading", startedAt: .now)
            do {
                try await session.client.upload(url, to: session.location)
                updateTransfer(transfer.id, status: .succeeded, detail: "Uploaded", finishedAt: .now)
                await session.reload()
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
        }
    }

    private func enqueueDownload(_ item: RemoteItem, directory: URL, session: RemoteSession) {
        let transfer = TransferTask(direction: .download, title: item.name, connectionName: session.profile.name)
        transfers.append(transfer)
        Task {
            updateTransfer(transfer.id, status: .running, detail: "Downloading", startedAt: .now)
            do {
                try await session.client.download(item, to: directory.appendingPathComponent(item.name))
                updateTransfer(transfer.id, status: .succeeded, detail: "Downloaded", finishedAt: .now)
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
        }
    }

    private func enqueueCopy(_ item: RemoteItem, destination: String, session: RemoteSession) {
        let transfer = TransferTask(direction: .sync, title: "Copy \(item.name)", connectionName: session.profile.name)
        transfers.append(transfer)
        Task {
            updateTransfer(transfer.id, status: .running, detail: "Copying", startedAt: .now)
            do {
                try await session.client.copy(item, to: destination)
                updateTransfer(transfer.id, status: .succeeded, detail: "Copied", finishedAt: .now)
                await session.reload()
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
        }
    }

    private func enqueueMove(_ item: RemoteItem, destination: String, session: RemoteSession) {
        let transfer = TransferTask(direction: .sync, title: "Move \(item.name)", connectionName: session.profile.name)
        transfers.append(transfer)
        Task {
            updateTransfer(transfer.id, status: .running, detail: "Moving", startedAt: .now)
            do {
                try await session.client.move(item, to: destination)
                updateTransfer(transfer.id, status: .succeeded, detail: "Moved", finishedAt: .now)
                await session.reload()
            } catch {
                updateTransfer(transfer.id, status: .failed, detail: error.localizedDescription, finishedAt: .now)
                lastError = error.localizedDescription
            }
        }
    }

    private func updateTransfer(_ id: UUID, status: TransferStatus, detail: String, startedAt: Date? = nil, finishedAt: Date? = nil) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[index].status = status
        transfers[index].detail = detail
        if let startedAt { transfers[index].startedAt = startedAt }
        if let finishedAt { transfers[index].finishedAt = finishedAt }
    }

    private func markSynced(ruleID: UUID, profileID: UUID) {
        guard let profileIndex = profiles.firstIndex(where: { $0.id == profileID }), let ruleIndex = profiles[profileIndex].syncRules.firstIndex(where: { $0.id == ruleID }) else { return }
        profiles[profileIndex].syncRules[ruleIndex].lastSyncedAt = .now
        Task { try? await profileStore.save(profiles) }
    }

    private func runDueSyncs() {
        let now = Date.now
        for profile in profiles where sessions[profile.id] != nil {
            for rule in profile.syncRules where rule.isEnabled {
                let dueDate = rule.lastSyncedAt?.addingTimeInterval(Double(rule.intervalMinutes * 60)) ?? .distantPast
                if now >= dueDate { sync(profile: profile, rule: rule) }
            }
        }
    }
}
