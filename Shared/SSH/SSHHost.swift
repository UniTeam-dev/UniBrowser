import Foundation

/// A saved SSH server. Synced between the devices together with its secret;
/// a deletion stays as a tombstone (see `SSHHostMerge`).
struct SSHHost: Codable, Sendable, Identifiable, Hashable {
    enum Auth: String, Codable, Sendable { case password, key }

    var id: UUID
    var name: String
    var address: String
    var port: Int
    var username: String
    var auth: Auth
    /// Connect through the paired Mac (iPhone only).
    var viaMac: Bool
    var modifiedAt: Date
    var deleted: Bool

    /// The name, else `user@address`.
    var displayName: String { name.isEmpty ? "\(username)@\(address)" : name }

    init(id: UUID = UUID(), name: String = "", address: String, port: Int = 22, username: String,
         auth: Auth = .password, viaMac: Bool = false, modifiedAt: Date = .now, deleted: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.auth = auth
        self.viaMac = viaMac
        self.modifiedAt = modifiedAt
        self.deleted = deleted
    }
}

struct SSHSecret: Codable, Sendable, Hashable {
    var password: String?
    var privateKey: String?
    var passphrase: String?

    init(password: String? = nil, privateKey: String? = nil, passphrase: String? = nil) {
        self.password = password
        self.privateKey = privateKey
        self.passphrase = passphrase
    }
}

/// A host with its secret: what travels between the devices; the winner's secret goes with it.
struct SyncedSSHHost: Codable, Sendable, Hashable, Identifiable {
    var host: SSHHost
    var secret: SSHSecret
    var id: UUID { host.id }
}

/// Same rules as `BookmarkMerge`: per id, the later `modifiedAt` wins.
enum SSHHostMerge {
    static func wins(_ a: SyncedSSHHost, over b: SyncedSSHHost) -> Bool {
        if a.host.modifiedAt != b.host.modifiedAt { return a.host.modifiedAt > b.host.modifiedAt }
        func key(_ x: SyncedSSHHost) -> [String] {
            [x.host.deleted ? "1" : "0", x.host.name, x.host.address, String(x.host.port), x.host.username,
             x.host.auth.rawValue, x.host.viaMac ? "1" : "0",
             x.secret.password ?? "", x.secret.privateKey ?? "", x.secret.passphrase ?? ""]
        }
        return key(b).lexicographicallyPrecedes(key(a))
    }

    static func merged(_ local: [SyncedSSHHost], _ remote: [SyncedSSHHost]) -> [SyncedSSHHost] {
        var result = local
        var index = Dictionary(local.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in remote {
            if let i = index[item.id] {
                if wins(item, over: result[i]) { result[i] = item }
            } else {
                index[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// Echo rule: answer a received list only when the sender would gain something from `mine`.
    static func needsReply(received: [SyncedSSHHost], mine: [SyncedSSHHost]) -> Bool {
        merged(received, mine) != received
    }

    static func pruned(_ items: [SyncedSSHHost], now: Date) -> [SyncedSSHHost] {
        items.filter { !$0.host.deleted || now.timeIntervalSince($0.host.modifiedAt) < BookmarkMerge.tombstoneLifetime }
    }
}

/// A server key the user has trusted. `hostPort` is "host:port".
struct KnownHost: Codable, Sendable, Hashable {
    var hostPort: String
    var keyType: String
    var fingerprintSHA256: String
    var publicKey: String
    var addedAt: Date
}

enum KnownHostCheck: Equatable {
    case trusted, unknown, changed(previous: KnownHost)
}

enum KnownHostMerge {
    /// Union by `hostPort`; the later `addedAt` wins (local on a tie).
    static func merged(_ local: [KnownHost], _ remote: [KnownHost]) -> [KnownHost] {
        var result = local
        var index = Dictionary(local.enumerated().map { ($1.hostPort, $0) }, uniquingKeysWith: { first, _ in first })
        for item in remote {
            if let i = index[item.hostPort] {
                if item.addedAt > result[i].addedAt { result[i] = item }
            } else {
                index[item.hostPort] = result.count
                result.append(item)
            }
        }
        return result
    }

    static func needsReply(received: [KnownHost], mine: [KnownHost]) -> Bool {
        merged(received, mine) != received
    }

    static func check(_ all: [KnownHost], hostPort: String, publicKey: String) -> KnownHostCheck {
        guard let known = all.first(where: { $0.hostPort == hostPort }) else { return .unknown }
        return known.publicKey == publicKey ? .trusted : .changed(previous: known)
    }
}
