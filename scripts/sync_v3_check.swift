// Self-check for the sync v3 messages in Shared/ViaMac/ViaMacProtocol.swift:
//   swiftc -parse-as-library UniBrowser/Models/Space.swift UniBrowser/Models/SessionSnapshot.swift Shared/Library/BookmarkMerge.swift Shared/Library/HistoryStore.swift Shared/ViaMac/ViaMacAddress.swift Shared/ViaMac/ViaMacProtocol.swift Shared/SSH/SSHHost.swift scripts/sync_v3_check.swift -o /tmp/sync_v3_check && /tmp/sync_v3_check
import Foundation

@main
enum SyncV3Check {
    static func roundTrip(_ message: SyncMessage) -> SyncMessage {
        try! JSONDecoder().decode(SyncMessage.self, from: try! JSONEncoder().encode(message))
    }

    static func main() {
        let at = Date(timeIntervalSince1970: 1_000)
        let hosts = [
            SyncedSSHHost(host: SSHHost(name: "nas", address: "10.0.0.2", port: 2222, username: "root", auth: .key, viaMac: true, modifiedAt: at),
                          secret: SSHSecret(privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----", passphrase: "p")),
            SyncedSSHHost(host: SSHHost(address: "gone", username: "u", modifiedAt: at, deleted: true), secret: SSHSecret()),
        ]
        let known = [KnownHost(hostPort: "10.0.0.2:2222", keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:abc",
                               publicKey: "ssh-ed25519 AAAA", addedAt: at)]

        guard case .sshHosts(let h) = roundTrip(.sshHosts(hosts)) else { preconditionFailure("sshHosts case") }
        precondition(h == hosts, "sshHosts round trip")
        guard case .knownHosts(let k) = roundTrip(.knownHosts(known)) else { preconditionFailure("knownHosts case") }
        precondition(k == known, "knownHosts round trip")

        let space = Space(name: "Main", colorHex: "#2563C9", groups: [], looseTabIDs: [])
        let session = SessionSnapshot(spaces: [space], activeSpaceID: space.id, tabs: [], archive: nil, modifiedAt: at)
        let hello = SyncMessage.hello(session: session, base: nil, savedPasswords: [], bookmarks: [], sshHosts: hosts, knownHosts: known)
        guard case .hello(_, let base, let saved, let bookmarks, let hh, let kk) = roundTrip(hello) else { preconditionFailure("hello case") }
        precondition(base == nil && saved.isEmpty && bookmarks.isEmpty && hh == hosts && kk == known, "hello round trip")

        precondition(String(decoding: ViaMacProtocol.alpn, as: UTF8.self).hasSuffix("/3"), "ALPN is /3")
        let legacy = ViaMacProtocol.legacyAlpns.map { String(decoding: $0, as: UTF8.self) }
        precondition(legacy == ["unibrowser/via-mac/2", "unibrowser/via-mac/1"], "/2 and /1 are legacy")
        print("sync v3: ok")
    }
}
