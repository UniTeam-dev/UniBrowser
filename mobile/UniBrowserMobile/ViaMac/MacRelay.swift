import Foundation
import Network
import Observation

/// The phone's side of the via-Mac mode: which domains go through the Mac and
/// whether the tunnel to it is up.
///
/// Route: WKWebView → SOCKS5 proxy on 127.0.0.1 (served by the in-app tunnel)
/// → encrypted QUIC tunnel (direct or via relay) → SOCKS proxy in UniBrowser
/// on the Mac → the Mac's corporate VPN. Host names are resolved on the Mac,
/// so internal DNS names work. The tunnel itself lands in stage 2–3.
@MainActor
@Observable
final class MacRelay {
    enum Path: Equatable {
        /// Same Wi-Fi or a punched-through NAT.
        case direct
        /// Through the relay server, which sees only ciphertext.
        case relay
    }

    enum Status: Equatable {
        case notPaired
        case connecting
        case connected(Path)
        case unreachable(reason: String)
    }

    /// Loopback port where the in-app tunnel exposes the Mac's SOCKS proxy.
    static let localProxyPort: NWEndpoint.Port = 47801

    private(set) var status: Status = .notPaired

    /// Domains sent through the Mac, e.g. "corp.example". Everything else goes direct.
    var workDomains: [String] {
        didSet {
            UserDefaults.standard.set(workDomains, forKey: Self.domainsKey)
            onProxiesChange?(proxyConfigurations())
        }
    }

    @ObservationIgnored var onProxiesChange: (@MainActor ([ProxyConfiguration]) -> Void)?

    private static let domainsKey = "viaMac.workDomains"

    init() {
        workDomains = UserDefaults.standard.stringArray(forKey: Self.domainsKey) ?? []
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// One SOCKS5 hop to the tunnel for the work domains. Failover is off on
    /// purpose: with the Mac unreachable a work page fails instead of quietly
    /// loading from the phone's own network.
    func proxyConfigurations() -> [ProxyConfiguration] {
        guard !workDomains.isEmpty else { return [] }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: Self.localProxyPort))
        proxy.matchDomains = workDomains
        proxy.allowFailover = false
        return [proxy]
    }

    func addDomain(_ raw: String) {
        let domain = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/*."))
        guard !domain.isEmpty, !workDomains.contains(domain) else { return }
        workDomains.append(domain)
    }

    func removeDomains(at offsets: IndexSet) {
        workDomains.remove(atOffsets: offsets)
    }
}
