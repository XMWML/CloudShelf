import CloudShelfCore
import Foundation

var failures: [String] = []

actor SyncMockClient: RemoteClient {
    private var directories: Set<String> = ["/"]
    private var uploadCount = 0

    func list(at path: String) async throws -> [RemoteItem] {
        directories
            .filter { $0 != "/" && RemotePath.parent(of: $0) == path }
            .map { RemoteItem(name: RemotePath.name(of: $0), path: $0, kind: .directory, size: nil, modifiedAt: nil) }
    }

    func createDirectory(named name: String, in parent: String) async throws {
        let path = RemotePath.join(parent, name)
        guard directories.insert(path).inserted else {
            throw CloudShelfError.commandFailed("WebDAV MKCOL failed (HTTP 405)")
        }
    }

    func delete(_ item: RemoteItem) async throws { }
    func rename(_ item: RemoteItem, to newName: String) async throws { }
    func move(_ item: RemoteItem, to directory: String) async throws { }
    func download(_ item: RemoteItem, to localURL: URL) async throws { }
    func upload(_ localURL: URL, to directory: String) async throws { uploadCount += 1 }
    func download(_ item: RemoteItem, to localURL: URL, progress: TransferProgressHandler?) async throws {
        try await download(item, to: localURL)
    }
    func upload(_ localURL: URL, to directory: String, progress: TransferProgressHandler?) async throws {
        try await upload(localURL, to: directory)
    }
    func copy(_ item: RemoteItem, to directory: String) async throws { }

    func uploadedCount() -> Int { uploadCount }
    func containsDirectory(_ path: String) -> Bool { directories.contains(path) }
}

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

check(RemotePath.normalized("folder//child/../report.txt") == "/folder/report.txt", "path normalization")
check(RemotePath.join("/folder", "child") == "/folder/child", "path join")
check(RemotePath.parent(of: "/folder/child") == "/folder", "path parent")

let profile = ConnectionProfile(name: "Server", protocolType: .sftp, host: "example.com")
check(profile.port == 22, "SFTP default port")
check(profile.basePath == "/", "default root path")
check(!profile.useTLS, "SFTP TLS default")

let rule = SyncRule(localFolder: "/tmp/local", remoteFolder: "backups/../daily", intervalMinutes: 0)
check(rule.remoteFolder == "/daily", "sync remote path normalization")
check(rule.intervalMinutes == 1, "sync interval lower bound")

let syncRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CloudShelfSmoke-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: syncRoot) }
do {
    let nested = syncRoot.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("one".utf8).write(to: nested.appendingPathComponent("one.txt"))
    try Data("two".utf8).write(to: nested.appendingPathComponent("two.txt"))
    let client = SyncMockClient()
    let syncRule = SyncRule(localFolder: syncRoot.path, remoteFolder: "/target", direction: .uploadOnly)
    let report = try await SyncEngine().synchronize(rule: syncRule, client: client)
    check(report.uploaded == 2, "sync uploads nested files")
    let uploadedCount = await client.uploadedCount()
    let containsNestedDirectory = await client.containsDirectory("/target/nested")
    check(uploadedCount == 2, "sync avoids duplicate uploads")
    check(containsNestedDirectory, "sync creates nested directory once")
} catch {
    failures.append("sync directory reuse: \(error.localizedDescription)")
}

if failures.isEmpty {
    print("CloudShelf core smoke checks passed (11 assertions).")
} else {
    fputs("CloudShelf smoke check failed: \(failures.joined(separator: ", "))\n", stderr)
    exit(1)
}
