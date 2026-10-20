import Foundation
import Security

/// Wire format of the link between the iPhone and the Mac app.
///
/// Both sides are iroh endpoints (QUIC with NAT traversal and relay fallback,
/// authenticated by their keys). Every bidirectional stream starts with one
/// `StreamKind` byte:
/// - `socks`: the rest is a raw SOCKS5 session, served by the Mac;
/// - `control`: one JSON `ControlRequest`, answered with one `ControlResponse`;
/// - `sync`: a long-lived stream of length-prefixed JSON `SyncMessage`s both
///   ways, carrying the live session mirror and the passwords.
enum ViaMacProtocol {
    /// Bumped whenever the sync messages change: two different versions refuse
    /// each other cleanly instead of failing to decode.
    static let alpn = Data("unibrowser/via-mac/3".utf8)
    /// Previous versions, newest first, accepted only to tell the other side to update.
    static let legacyAlpns = [Data("unibrowser/via-mac/2".utf8), Data("unibrowser/via-mac/1".utf8)]
    static let maxControlMessage: UInt32 = 4 << 20
    static let maxSyncFrame: UInt32 = 32 << 20
    /// How long a QR code from the Mac stays valid.
    static let pairingLifetime: TimeInterval = 10 * 60
}

enum StreamKind: UInt8 {
    case socks = 1
    case control = 2
    case sync = 3
}

enum ViaMacError: LocalizedError {
    case unexpectedEnd
    case timeout
    case notConnected
    case badPairingLink
    case pairingExpired
    case rejected(String)
    case socks(UInt8)
    case frameTooLarge
    /// The other device runs an older UniBrowser with an older link protocol.
    case outdatedMac

    var errorDescription: String? {
        switch self {
        case .unexpectedEnd: "Соединение оборвалось."
        case .timeout: "Mac не ответил вовремя."
        case .notConnected: "Нет связи с Mac."
        case .badPairingLink: "Это не код сопряжения UniBrowser."
        case .pairingExpired: "Код сопряжения устарел, покажите на Mac новый."
        case .rejected(let reason): reason
        case .socks(let code): "Ошибка прокси (\(code))."
        case .frameTooLarge: "Слишком большое сообщение синхронизации."
        case .outdatedMac: "Обновите UniBrowser на Mac: его версия не умеет связываться с этим iPhone."
        }
    }
}

/// What the Mac's QR code carries, as a `unibrowser://pair?d=…` link. The
/// system Camera opens the link straight in UniBrowser on the iPhone.
struct PairingPayload: Codable, Equatable, Sendable {
    /// The Mac's iroh endpoint id.
    var macID: String
    /// The Mac's home relay, a hint that speeds up the first connection.
    var relayURL: String?
    /// The Mac's own IP addresses (`ip:port`), dialled alongside the relay: a phone
    /// that can reach one connects without waiting on the relay.
    var addresses: [String]?
    /// The «Внешний адрес» set on the Mac (`host[:port]`, an IP or a DNS name); the phone
    /// resolves it before every connect and dials it alongside the others.
    var externalAddress: String?
    var macName: String
    /// One-time secret; the Mac accepts it once, before `expires`.
    var token: String
    var expires: Date

    static let scheme = "unibrowser"

    var link: String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = (try? encoder.encode(self)) ?? Data()
        return "\(Self.scheme)://pair?d=\(json.base64URLEncoded)"
    }

    init(macID: String, relayURL: String?, addresses: [String]?, externalAddress: String?, macName: String, token: String, expires: Date) {
        self.macID = macID
        self.relayURL = relayURL
        self.addresses = addresses
        self.externalAddress = externalAddress
        self.macName = macName
        self.token = token
        self.expires = expires
    }

    init(link: String) throws {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == Self.scheme, components.host == "pair",
              let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value,
              let json = Data(base64URLEncoded: encoded)
        else { throw ViaMacError.badPairingLink }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let payload = try? decoder.decode(PairingPayload.self, from: json) else {
            throw ViaMacError.badPairingLink
        }
        self = payload
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded
    }
}

enum ControlRequest: Codable, Sendable {
    /// First request from a phone the Mac doesn't know yet.
    case pair(token: String, deviceName: String)
    /// Open a page in a new tab on the Mac and bring the Mac app forward.
    case open(url: URL)
    /// A round trip that proves the link works: sent right after connecting and
    /// then every few seconds while connected. `path` is how the phone reaches the
    /// Mac on this link, once it knows.
    case ping(path: LinkPath? = nil)
}

struct ControlResponse: Codable, Sendable {
    var ok: Bool
    var error: String?
    var macName: String?
    /// The Mac's current IP addresses, in answers to `pair` and `ping`.
    var addresses: [String]?
    /// The Mac's home relay, in answers to `pair` and `ping`.
    var relayURL: String?
    /// The Mac's «Внешний адрес»; empty when it has none (nil: an older Mac that doesn't say).
    var externalAddress: String?

    static func failure(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }
}

/// A saved login as it travels between the devices.
struct SyncedCredential: Codable, Hashable, Sendable, Identifiable {
    var host: String
    var username: String
    var password: String

    var id: String { "\(host)\u{1F}\(username)" }
}

/// One frame on the `sync` stream. The phone opens the stream and starts with
/// `hello`; the Mac answers with the merged `session` and its `passwords`.
/// After that either side sends `session` whenever its tabs change, and the
/// later change wins.
enum SyncMessage: Codable, Sendable {
    /// Phone → Mac, once per connection: the phone's session, the last session
    /// both sides agreed on (nil before the first sync), logins saved on
    /// the phone that the Mac may not have yet, the phone's bookmarks, SSH hosts and trusted server keys.
    case hello(session: SessionSnapshot, base: SessionSnapshot?, savedPasswords: [SyncedCredential], bookmarks: [Bookmark],
               sshHosts: [SyncedSSHHost], knownHosts: [KnownHost])
    /// Either way: the sender's whole session after a change.
    case session(SessionSnapshot)
    /// Like `session`, but without space pictures because none changed since
    /// the last full frame on this stream. SyncChannel adds them back, so
    /// receivers only ever see `session`.
    case sessionKeepingImages(SessionSnapshot)
    /// Mac → phone: every login in the Mac's password store.
    case passwords([SyncedCredential])
    /// Phone → Mac: a login the user just saved on the phone.
    case savePassword(SyncedCredential)
    /// Either way: the sender's whole bookmark list, tombstones included, after
    /// any change (and from the Mac once after hello). The receiver merges and,
    /// if its result differs from what it got, sends its own list back.
    case bookmarks([Bookmark])
    /// Either way, like `bookmarks`: the sender's SSH hosts with their secrets, tombstones included.
    case sshHosts([SyncedSSHHost])
    /// Either way, like `bookmarks`: the sender's trusted server keys.
    case knownHosts([KnownHost])
    /// Either way: visits since the last batch sent to this peer, at most every 5 s.
    case history([Visit])
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
