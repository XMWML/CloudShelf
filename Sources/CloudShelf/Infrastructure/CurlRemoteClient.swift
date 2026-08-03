import Foundation

private enum CurlTransferDirection {
    case download
    case upload
}

private final class CurlProgressParser: @unchecked Sendable {
    private let direction: CurlTransferDirection
    private let progress: TransferProgressHandler
    private let lock = NSLock()
    private var unfinishedLine = ""
    private var lastCompletedBytes: Int64 = 0

    init(direction: CurlTransferDirection, progress: @escaping TransferProgressHandler) {
        self.direction = direction
        self.progress = progress
    }

    func consume(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self)
        lock.lock()
        let text = unfinishedLine + chunk
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\r" || $0 == "\n" })
        let hasTerminator = text.last == "\r" || text.last == "\n"
        unfinishedLine = hasTerminator ? "" : String(parts.last ?? "")
        let completedLines = hasTerminator ? parts : parts.dropLast()
        var values = [Int64]()
        for line in completedLines {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 6,
                  Int(tokens[0]) != nil,
                  let received = Self.byteCount(tokens[3]),
                  let uploaded = Self.byteCount(tokens[5]) else { continue }
            let value = direction == .download ? received : uploaded
            guard value >= lastCompletedBytes else { continue }
            lastCompletedBytes = value
            values.append(value)
        }
        lock.unlock()

        values.forEach { progress($0, nil) }
    }

    private static func byteCount(_ token: Substring) -> Int64? {
        let value = String(token).lowercased()
        let suffix = value.last
        let multiplier: Double
        let number: String
        switch suffix {
        case "k": multiplier = 1_024; number = String(value.dropLast())
        case "m": multiplier = 1_024 * 1_024; number = String(value.dropLast())
        case "g": multiplier = 1_024 * 1_024 * 1_024; number = String(value.dropLast())
        case "t": multiplier = 1_024 * 1_024 * 1_024 * 1_024; number = String(value.dropLast())
        default: multiplier = 1; number = value
        }
        guard let parsed = Double(number) else { return nil }
        return Int64(parsed * multiplier)
    }
}

actor CurlRemoteClient: RemoteClient {
    private let profile: ConnectionProfile
    private let endpoint: RemoteEndpoint
    private let password: String?

    init(profile: ConnectionProfile, password: String?) throws {
        let endpoint = try RemoteEndpoint(profile: profile)
        self.profile = endpoint.profile
        self.endpoint = endpoint
        self.password = password
    }

    func list(at path: String) async throws -> [RemoteItem] {
        switch profile.protocolType {
        case .ftp:
            let output = try await curl(url: endpoint.url(for: path), arguments: ["--disable-epsv"])
            return UnixListingParser.parse(output.stdout, parent: RemotePath.normalized(path))
        case .webDAV:
            let requestBody = """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:">
              <d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop>
            </d:propfind>
            """
            let bodyURL = try TemporaryFiles.write(requestBody, suffix: "xml")
            defer { try? FileManager.default.removeItem(at: bodyURL) }
            let output = try await curl(
                url: endpoint.url(for: path),
                arguments: ["--request", "PROPFIND", "--header", "Depth: 1", "--header", "Content-Type: application/xml; charset=utf-8", "--data-binary", "@\(bodyURL.path)"]
            )
            return try WebDAVListingParser.parse(output.stdout, endpoint: endpoint, requestedPath: path)
        case .sftp:
            throw CloudShelfError.unsupported("The selected client cannot use SFTP.")
        }
    }

    func createDirectory(named name: String, in parent: String) async throws {
        try validateName(name)
        let target = RemotePath.join(parent, name)
        switch profile.protocolType {
        case .ftp:
            _ = try await curl(url: endpoint.url(for: parent), arguments: ["--quote", "MKD \(endpoint.serverPath(for: target))"])
        case .webDAV:
            _ = try await curl(url: endpoint.url(for: target), arguments: ["--request", "MKCOL"])
        case .sftp:
            throw CloudShelfError.unsupported("The selected client cannot use SFTP.")
        }
    }

    func delete(_ item: RemoteItem) async throws {
        switch profile.protocolType {
        case .ftp:
            if item.isDirectory {
                for child in try await list(at: item.path) { try await delete(child) }
                _ = try await curl(url: endpoint.url(for: RemotePath.parent(of: item.path)), arguments: ["--quote", "RMD \(endpoint.serverPath(for: item.path))"])
            } else {
                _ = try await curl(url: endpoint.url(for: RemotePath.parent(of: item.path)), arguments: ["--quote", "DELE \(endpoint.serverPath(for: item.path))"])
            }
        case .webDAV:
            _ = try await curl(url: endpoint.url(for: item.path), arguments: ["--request", "DELETE"])
        case .sftp:
            throw CloudShelfError.unsupported("The selected client cannot use SFTP.")
        }
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
        try await download(item, to: localURL, resumeFrom: 0, progress: nil)
    }

    func download(_ item: RemoteItem, to localURL: URL, progress: TransferProgressHandler?) async throws {
        try await download(item, to: localURL, resumeFrom: 0, progress: progress)
    }

    func supportsResumableTransfers() async -> Bool { profile.protocolType == .ftp }

    func download(_ item: RemoteItem, to localURL: URL, resumeFrom: Int64, progress: TransferProgressHandler?) async throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var arguments = ["--output", localURL.path]
        if resumeFrom > 0 { arguments.insert(contentsOf: ["--continue-at", String(resumeFrom)], at: 0) }
        _ = try await curl(url: endpoint.url(for: item.path), arguments: arguments, progress: progress, direction: .download, allowsRetry: true)
    }

    func upload(_ localURL: URL, to directory: String) async throws {
        try await upload(localURL, to: directory, resumeFrom: 0, progress: nil)
    }

    func upload(_ localURL: URL, to directory: String, progress: TransferProgressHandler?) async throws {
        try await upload(localURL, to: directory, resumeFrom: 0, progress: progress)
    }

    func upload(_ localURL: URL, to directory: String, resumeFrom: Int64, progress: TransferProgressHandler?) async throws {
        let target = RemotePath.join(directory, localURL.lastPathComponent)
        var arguments = ["--upload-file", localURL.path]
        if resumeFrom > 0 { arguments.insert(contentsOf: ["--continue-at", String(resumeFrom)], at: 0) }
        _ = try await curl(url: endpoint.url(for: target), arguments: arguments, progress: progress, direction: .upload, allowsRetry: true)
    }

    func copy(_ item: RemoteItem, to directory: String) async throws {
        guard profile.protocolType == .webDAV else {
            try await copyViaTemporaryFile(item, to: directory)
            return
        }
        let destination = try endpoint.url(for: RemotePath.join(directory, item.name)).absoluteString
        _ = try await curl(url: endpoint.url(for: item.path), arguments: ["--request", "COPY", "--header", "Destination: \(destination)", "--header", "Overwrite: T"])
    }

    private func copyViaTemporaryFile(_ item: RemoteItem, to directory: String) async throws {
        if item.isDirectory {
            try await createDirectory(named: item.name, in: directory)
            let childDestination = RemotePath.join(directory, item.name)
            for child in try await list(at: item.path) { try await copyViaTemporaryFile(child, to: childDestination) }
        } else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CloudShelf-copy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }
            let local = scratch.appendingPathComponent(item.name)
            try await download(item, to: local)
            try await upload(local, to: directory)
        }
    }

    private func movePath(_ source: String, destination: String) async throws {
        switch profile.protocolType {
        case .ftp:
            _ = try await curl(
                url: endpoint.url(for: RemotePath.parent(of: source)),
                arguments: ["--quote", "RNFR \(endpoint.serverPath(for: source))", "--quote", "RNTO \(endpoint.serverPath(for: destination))"]
            )
        case .webDAV:
            let destinationURL = try endpoint.url(for: destination).absoluteString
            _ = try await curl(url: endpoint.url(for: source), arguments: ["--request", "MOVE", "--header", "Destination: \(destinationURL)", "--header", "Overwrite: T"])
        case .sftp:
            throw CloudShelfError.unsupported("The selected client cannot use SFTP.")
        }
    }

    private func curl(
        url: URL,
        arguments: [String],
        progress: TransferProgressHandler? = nil,
        direction: CurlTransferDirection? = nil,
        allowsRetry: Bool = false
    ) async throws -> ProcessOutput {
        guard let password else { throw CloudShelfError.missingCredential }
        let config = try TemporaryFiles.write(curlConfiguration(for: url, password: password), suffix: "curl")
        defer { try? FileManager.default.removeItem(at: config) }
        let parser = progress.flatMap { progress in
            direction.map { CurlProgressParser(direction: $0, progress: progress) }
        }
        var commandArguments = ["--config", config.path, "--fail", "--show-error", "--connect-timeout", "20"]
        if allowsRetry { commandArguments += ["--retry", "2", "--retry-delay", "1"] }
        if parser == nil { commandArguments.append("--silent") }
        commandArguments += arguments
        return try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: commandArguments,
            onStandardErrorData: { data in parser?.consume(data) }
        )
    }

    private func curlConfiguration(for url: URL, password: String) -> String {
        var lines = [
            "url = \"\(curlQuoted(url.absoluteString))\"",
            "user = \"\(curlQuoted(profile.username + ":" + password))\""
        ]
        if profile.protocolType == .webDAV { lines.append("anyauth") }
        return lines.joined(separator: "\n")
    }

    private func curlQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func validateName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\n"), name != ".", name != ".." else {
            throw CloudShelfError.invalidProfile("Names cannot contain a slash or line break.")
        }
    }
}

final class WebDAVListingParser: NSObject, XMLParserDelegate {
    private struct Entry {
        var href = ""
        var name = ""
        var isDirectory = false
        var size: Int64?
        var modifiedAt: Date?
    }

    private var entries: [Entry] = []
    private var entry: Entry?
    private var currentElement = ""
    private var buffer = ""

    static func parse(_ xml: String, endpoint: RemoteEndpoint, requestedPath: String) throws -> [RemoteItem] {
        let parser = XMLParser(data: Data(xml.utf8))
        let delegate = WebDAVListingParser()
        parser.delegate = delegate
        guard parser.parse() else { throw CloudShelfError.invalidResponse(parser.parserError?.localizedDescription ?? "WebDAV returned invalid XML.") }
        let requested = RemotePath.normalized(requestedPath)
        return delegate.entries.compactMap { entry in
            guard !entry.href.isEmpty else { return nil }
            let remotePath = Self.path(fromHref: entry.href)
            let path = endpoint.virtualPath(forServerPath: remotePath)
            guard path != requested else { return nil }
            let name = entry.name.isEmpty ? RemotePath.name(of: path) : entry.name
            guard !name.isEmpty else { return nil }
            return RemoteItem(name: name, path: path, kind: entry.isDirectory ? .directory : .file, size: entry.size, modifiedAt: entry.modifiedAt)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func path(fromHref href: String) -> String {
        let path = URL(string: href)?.path ?? href
        return RemotePath.normalized(path.removingPercentEncoding ?? path)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        currentElement = name.lowercased()
        buffer = ""
        if currentElement == "response" { entry = Entry() }
        if currentElement == "collection" { entry?.isDirectory = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = (qName ?? elementName).split(separator: ":").last.map(String.init) ?? elementName
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name.lowercased() {
        case "href": entry?.href += value
        case "displayname": entry?.name += value
        case "getcontentlength": entry?.size = Int64(value)
        case "getlastmodified": entry?.modifiedAt = Self.httpDateFormatter.date(from: value)
        case "response": if let entry { entries.append(entry) }; entry = nil
        default: break
        }
        buffer = ""
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
