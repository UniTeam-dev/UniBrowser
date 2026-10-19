import Foundation

/// How the phone reached the Mac on its current link; the phone reports it in
/// `ping` so the Mac can show it next to the iPhone.
enum LinkPath: String, Codable, Sendable {
    /// Direct, to the Mac's external address (a router port forward).
    case external
    /// Direct otherwise: same Wi-Fi or a punched-through NAT.
    case direct
    /// Through a relay server («сервер связи»).
    case relay

    var title: String {
        switch self {
        case .external: "Напрямую через внешний адрес"
        case .direct: "Напрямую"
        case .relay: "Через сервер связи"
        }
    }
}

/// The «Внешний адрес» and «Свой сервер связи» settings: parsing and checks.
/// Checked by `scripts/via_mac_address_check.swift`.
enum ViaMacAddress {
    /// The Mac's fixed UDP port unless the user picks another.
    static let defaultPort: UInt16 = 47802

    /// «host», «host:port», «[v6]:port» or a bare IPv6 address. The host is an IP
    /// address or a DNS name; nil when the text isn't one of these.
    static func parse(_ text: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
        let text = text.trimmingCharacters(in: .whitespaces).lowercased()
        var host = text
        var portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return nil }
                portText = rest.dropFirst()
            }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.firstIndex(of: ":") {
            host = String(text[..<colon])
            portText = text[text.index(after: colon)...]
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_:")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        // A colon left in the host means IPv6, which needs at least two of them.
        if host.contains(":"), host.filter({ $0 == ":" }).count < 2 { return nil }
        guard let portText else { return (host, defaultPort) }
        guard let port = UInt16(portText), port > 0 else { return nil }
        return (host, port)
    }

    /// `host:port`, with an IPv6 host in brackets, as iroh writes socket addresses.
    static func join(_ host: String, _ port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    /// An http(s) URL with a host: what iroh accepts as a relay.
    static func isValidRelay(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), !host.isEmpty else { return false }
        return true
    }

    /// The relay to bind with instead of iroh's defaults, or nil for the defaults:
    /// no URL, n0's own servers (`*.iroh.link`), or a malformed one.
    static func customRelay(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), isValidRelay(text),
              let host = URL(string: text)?.host()?.lowercased() else { return nil }
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        return bare == "iroh.link" || bare.hasSuffix(".iroh.link") ? nil : text
    }
}
