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
    static let alpn = Data("unibrowser/via-mac/1".utf8)
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

    init(macID: String, relayURL: String?, macName: String, token: String, expires: Date) {
        self.macID = macID
        self.relayURL = relayURL
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
}

struct ControlResponse: Codable, Sendable {
    var ok: Bool
    var error: String?
    var macName: String?

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
    /// both sides agreed on (nil before the first sync) and logins saved on
    /// the phone that the Mac may not have yet.
    case hello(session: SessionSnapshot, base: SessionSnapshot?, savedPasswords: [SyncedCredential])
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
