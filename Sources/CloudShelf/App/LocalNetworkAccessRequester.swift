import Foundation
import Network
import CloudShelfCore

@MainActor
final class LocalNetworkAccessRequester {
    static let shared = LocalNetworkAccessRequester()

    private var requestedTargets = Set<String>()
    private var connection: NWConnection?
    private var browser: NWBrowser?
    private var didStartBonjourProbe = false
    private let queue = DispatchQueue(label: "CloudShelf.LocalNetworkAccess")

    private init() {}

    func requestAccess(for profile: ConnectionProfile) {
        startBonjourProbeIfNeeded()
        guard let target = target(for: profile) else { return }
        guard requestedTargets.insert("\(target.host):\(target.port)").inserted else { return }

        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: NWEndpoint.Port(rawValue: target.port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready, .failed, .cancelled:
                connection?.cancel()
                DispatchQueue.main.async {
                    guard self?.connection === connection else { return }
                    self?.connection = nil
                }
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Keep the probe alive while macOS displays a Local Network permission sheet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak connection] in
            guard self?.connection === connection else { return }
            connection?.cancel()
            self?.connection = nil
        }
    }

    private func startBonjourProbeIfNeeded() {
        guard !didStartBonjourProbe else { return }
        didStartBonjourProbe = true

        let browser = NWBrowser(for: .bonjour(type: "_webdav._tcp", domain: nil), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard case .failed = state else { return }
            DispatchQueue.main.async {
                guard self?.browser === browser else { return }
                self?.browser = nil
            }
        }
        browser.start(queue: queue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak browser] in
            guard self?.browser === browser else { return }
            browser?.cancel()
            self?.browser = nil
        }
    }

    private func target(for profile: ConnectionProfile) -> (host: String, port: UInt16)? {
        let address = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: address), let host = components.host, !host.isEmpty {
            let unbracketedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let port = components.port ?? profile.protocolType.defaultPort
            guard let networkPort = UInt16(exactly: port) else { return nil }
            return (unbracketedHost, networkPort)
        }

        guard let networkPort = UInt16(exactly: profile.port) else { return nil }
        return (address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), networkPort)
    }
}
