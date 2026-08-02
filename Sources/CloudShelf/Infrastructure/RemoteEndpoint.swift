import Foundation

struct RemoteEndpoint: Sendable {
    let profile: ConnectionProfile

    init(profile: ConnectionProfile) throws {
        let trimmedHost = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw CloudShelfError.invalidProfile("请填写服务器地址。")
        }

        var resolved = profile
        if profile.protocolType == .webDAV, trimmedHost.contains("://") {
            guard let components = URLComponents(string: trimmedHost),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = components.host, !host.isEmpty else {
                throw CloudShelfError.invalidProfile("WebDAV 地址必须是完整的 http:// 或 https:// URL。")
            }
            guard components.query == nil, components.fragment == nil else {
                throw CloudShelfError.invalidProfile("WebDAV 服务器地址不能包含查询参数或锚点。")
            }
            resolved.host = host
            resolved.port = components.port ?? profile.port
            resolved.useTLS = scheme == "https"
            let urlPath = components.path.isEmpty ? "/" : components.path
            resolved.basePath = profile.basePath == "/" ? RemotePath.normalized(urlPath) : RemotePath.join(urlPath, profile.basePath)
            self.profile = resolved
            return
        }

        guard !trimmedHost.contains("://"), !trimmedHost.contains("/") else {
            throw CloudShelfError.invalidProfile("FTP 和 SFTP 请只填写主机名或 IP 地址；WebDAV 可填写完整 URL。")
        }
        self.profile = resolved
    }

    func serverPath(for path: String) -> String {
        RemotePath.normalized(profile.basePath + "/" + RemotePath.normalized(path))
    }

    func virtualPath(forServerPath path: String) -> String {
        let serverPath = RemotePath.normalized(path)
        let base = RemotePath.normalized(profile.basePath)
        guard base != "/" else { return serverPath }
        guard serverPath == base || serverPath.hasPrefix(base + "/") else { return serverPath }
        let suffix = String(serverPath.dropFirst(base.count))
        return suffix.isEmpty ? "/" : RemotePath.normalized(suffix)
    }

    func url(for path: String) throws -> URL {
        var components = URLComponents()
        switch profile.protocolType {
        case .ftp: components.scheme = profile.useTLS ? "ftps" : "ftp"
        case .sftp: components.scheme = "sftp"
        case .webDAV: components.scheme = profile.useTLS ? "https" : "http"
        }
        components.host = profile.host
        components.port = profile.port
        components.percentEncodedPath = Self.percentEncodedPath(serverPath(for: path))
        guard let url = components.url else { throw CloudShelfError.invalidProfile("The server address is not valid.") }
        return url
    }

    private static func percentEncodedPath(_ path: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
            .joined(separator: "/")
    }
}

enum UnixListingParser {
    static func parse(_ output: String, parent: String) -> [RemoteItem] {
        output.split(whereSeparator: \ .isNewline).compactMap { line in
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("total "), !value.hasPrefix("sftp>") else { return nil }
            let parts = value.split(maxSplits: 8, whereSeparator: \ .isWhitespace)
            guard parts.count >= 9 else {
                let name = value.trimmingCharacters(in: .whitespaces)
                return name == "." || name == ".." ? nil : RemoteItem(name: name, path: RemotePath.join(parent, name), kind: .unknown, size: nil, modifiedAt: nil)
            }
            let permissions = String(parts[0])
            let nameWithTarget = String(parts[8])
            let name = nameWithTarget.components(separatedBy: " -> ").first ?? nameWithTarget
            guard name != ".", name != ".." else { return nil }
            let kind: RemoteItem.Kind
            switch permissions.first {
            case "d": kind = .directory
            case "l": kind = .symlink
            case "-": kind = .file
            default: kind = .unknown
            }
            return RemoteItem(
                name: name,
                path: RemotePath.join(parent, name),
                kind: kind,
                size: Int64(parts[4]),
                modifiedAt: nil
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
