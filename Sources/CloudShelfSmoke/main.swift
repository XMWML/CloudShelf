import CloudShelfCore
import Foundation

var failures: [String] = []

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

if failures.isEmpty {
    print("CloudShelf core smoke checks passed (7 assertions).")
} else {
    fputs("CloudShelf smoke check failed: \(failures.joined(separator: ", "))\n", stderr)
    exit(1)
}
