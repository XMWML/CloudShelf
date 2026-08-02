import Foundation

actor WebDAVRemoteClient: RemoteClient {
    private let profile: ConnectionProfile
    private let endpoint: RemoteEndpoint
    private let session: URLSession
    private let authenticationDelegate: WebDAVAuthenticationDelegate
    private let username: String
    private let password: String

    init(profile: ConnectionProfile, password: String?) throws {
        guard let password else { throw CloudShelfError.missingCredential }
        let endpoint = try RemoteEndpoint(profile: profile)
        self.profile = endpoint.profile
        self.endpoint = endpoint
        self.username = endpoint.profile.username
        self.password = password
        let delegate = WebDAVAuthenticationDelegate(username: endpoint.profile.username, password: password, progress: nil)
        self.authenticationDelegate = delegate
        self.session = URLSession(configuration: Self.sessionConfiguration(), delegate: delegate, delegateQueue: nil)
    }

    func list(at path: String) async throws -> [RemoteItem] {
        let requestBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:">
          <d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop>
        </d:propfind>
        """
        let request = try request(
            path: path,
            method: "PROPFIND",
            headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"],
            body: Data(requestBody.utf8)
        )
        let (data, _) = try await execute(request, operation: "列出目录")
        return try WebDAVListingParser.parse(String(decoding: data, as: UTF8.self), endpoint: endpoint, requestedPath: path)
    }

    func createDirectory(named name: String, in parent: String) async throws {
        try validateName(name)
        let request = try request(path: RemotePath.join(parent, name), method: "MKCOL")
        _ = try await execute(request, operation: "创建文件夹")
    }

    func delete(_ item: RemoteItem) async throws {
        let request = try request(path: item.path, method: "DELETE")
        _ = try await execute(request, operation: "删除")
    }

    func rename(_ item: RemoteItem, to newName: String) async throws {
        try validateName(newName)
        let destination = RemotePath.join(RemotePath.parent(of: item.path), newName)
        try await movePath(item.path, destination: destination)
    }

    func move(_ item: RemoteItem, to directory: String) async throws {
        try await movePath(item.path, destination: RemotePath.join(directory, item.name))
    }

    func download(_ item: RemoteItem, to localURL: URL) async throws {
        try await download(item, to: localURL, progress: nil)
    }

    func download(_ item: RemoteItem, to localURL: URL, progress: TransferProgressHandler?) async throws {
        let request = try request(path: item.path, method: "GET")
        let delegate = WebDAVAuthenticationDelegate(username: username, password: password, progress: progress)
        let transferSession = URLSession(configuration: Self.sessionConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { transferSession.invalidateAndCancel() }
        do {
            let (temporaryURL, response) = try await transferSession.download(for: request)
            try validate(response, operation: "下载")
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: localURL.path) {
                try FileManager.default.removeItem(at: localURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: localURL)
        } catch let error as CloudShelfError {
            throw error
        } catch {
            throw CloudShelfError.commandFailed("WebDAV 下载失败：\(networkErrorDescription(error))")
        }
    }

    func upload(_ localURL: URL, to directory: String) async throws {
        try await upload(localURL, to: directory, progress: nil)
    }

    func upload(_ localURL: URL, to directory: String, progress: TransferProgressHandler?) async throws {
        let target = RemotePath.join(directory, localURL.lastPathComponent)
        let request = try request(path: target, method: "PUT")
        let delegate = WebDAVAuthenticationDelegate(username: username, password: password, progress: progress)
        let transferSession = URLSession(configuration: Self.sessionConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { transferSession.invalidateAndCancel() }
        do {
            let (_, response) = try await transferSession.upload(for: request, fromFile: localURL)
            try validate(response, operation: "上传")
        } catch let error as CloudShelfError {
            throw error
        } catch {
            throw CloudShelfError.commandFailed("WebDAV 上传失败：\(networkErrorDescription(error))")
        }
    }

    func copy(_ item: RemoteItem, to directory: String) async throws {
        let destination = try endpoint.url(for: RemotePath.join(directory, item.name)).absoluteString
        let request = try request(
            path: item.path,
            method: "COPY",
            headers: ["Destination": destination, "Overwrite": "T", "Depth": "infinity"]
        )
        _ = try await execute(request, operation: "复制")
    }

    private func movePath(_ source: String, destination: String) async throws {
        let destinationURL = try endpoint.url(for: destination).absoluteString
        let request = try request(
            path: source,
            method: "MOVE",
            headers: ["Destination": destinationURL, "Overwrite": "T"]
        )
        _ = try await execute(request, operation: "移动")
    }

    private func request(path: String, method: String, headers: [String: String] = [:], body: Data? = nil) throws -> URLRequest {
        var request = URLRequest(url: try endpoint.url(for: path))
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        return request
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return configuration
    }

    private func execute(_ request: URLRequest, operation: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            let httpResponse = try validate(response, operation: operation, body: data)
            return (data, httpResponse)
        } catch let error as CloudShelfError {
            throw error
        } catch {
            throw CloudShelfError.commandFailed("WebDAV \(operation)失败：\(networkErrorDescription(error))")
        }
    }

    private func networkErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return error.localizedDescription
        }
        let code = URLError.Code(rawValue: nsError.code)

        switch code {
        case .notConnectedToInternet:
            return "系统网络框架将此连接标记为未联网。请检查 VPN、代理或“网络扩展”是否正在拦截 CloudShelf；将本应用设为直连后重试。原始原因：\(error.localizedDescription)"
        case .cannotConnectToHost, .networkConnectionLost:
            return "系统无法建立到服务器的连接。请检查服务器地址、网络和 VPN、代理或“网络扩展”的直连规则。原始原因：\(error.localizedDescription)"
        case .timedOut:
            return "连接服务器超时。请检查服务器是否可达，以及 VPN、代理或“网络扩展”的直连规则。原始原因：\(error.localizedDescription)"
        default:
            return error.localizedDescription
        }
    }

    @discardableResult
    private func validate(_ response: URLResponse, operation: String, body: Data? = nil) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudShelfError.invalidResponse("WebDAV \(operation)没有返回 HTTP 响应。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = body.flatMap { String(data: $0, encoding: .utf8) }
                .map { String($0.prefix(500)).trimmingCharacters(in: .whitespacesAndNewlines) }
            let suffix = detail.map { "：\($0)" } ?? ""
            throw CloudShelfError.commandFailed("WebDAV \(operation)失败（HTTP \(httpResponse.statusCode)）\(suffix)")
        }
        return httpResponse
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), name != ".", name != ".." else {
            throw CloudShelfError.invalidProfile("名称不能包含斜杠或换行。")
        }
    }
}

private final class WebDAVAuthenticationDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let credential: URLCredential
    private let progress: TransferProgressHandler?

    init(username: String, password: String, progress: TransferProgressHandler?) {
        credential = URLCredential(user: username, password: password, persistence: .forSession)
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest:
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progress?(totalBytesSent, totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) { }
}
