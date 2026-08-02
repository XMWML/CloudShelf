import Foundation

struct SyncState: Codable, Sendable {
    let localPaths: Set<String>
    let remotePaths: Set<String>
}

actor SyncStateStore {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func load(ruleID: UUID) -> SyncState? {
        let url = stateURL(for: ruleID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: data)
    }

    func save(_ state: SyncState, ruleID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL(for: ruleID), options: .atomic)
    }

    func remove(ruleID: UUID) {
        try? FileManager.default.removeItem(at: stateURL(for: ruleID))
    }

    private func stateURL(for ruleID: UUID) -> URL {
        directory.appendingPathComponent("\(ruleID.uuidString).json")
    }
}
