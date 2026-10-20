// Self-check for Shared/SSH/SSHHost.swift:
//   swiftc -parse-as-library Shared/Library/BookmarkMerge.swift Shared/SSH/SSHHost.swift scripts/ssh_merge_check.swift -o /tmp/ssh_merge_check && /tmp/ssh_merge_check
import Foundation

@main
enum SSHMergeCheck {
    static func at(_ s: Double) -> Date { Date(timeIntervalSince1970: s) }

    static func synced(_ id: UUID, address: String, password: String, t: Double, deleted: Bool = false) -> SyncedSSHHost {
        SyncedSSHHost(host: SSHHost(id: id, name: "", address: address, username: "u", modifiedAt: at(t), deleted: deleted),
                      secret: SSHSecret(password: password))
    }

    static func main() {
        let id = UUID()
        let local = synced(id, address: "a", password: "1", t: 1)
        let remote = synced(id, address: "b", password: "2", t: 2)
        for r in [SSHHostMerge.merged([local], [remote]), SSHHostMerge.merged([remote], [local])] {
            precondition(r.count == 1 && r[0].host.address == "b" && r[0].secret.password == "2", "later wins with its secret")
        }

        let x = synced(id, address: "a", password: "1", t: 5), y = synced(id, address: "a", password: "2", t: 5)
        precondition(SSHHostMerge.wins(x, over: y) != SSHHostMerge.wins(y, over: x), "equal time tie-break is antisymmetric")
        precondition(SSHHostMerge.merged([x], [y]) == SSHHostMerge.merged([y], [x]), "equal time: same winner on both sides")

        let l1 = UUID(), r1 = UUID()
        let m = SSHHostMerge.merged([synced(l1, address: "l", password: "", t: 1)], [synced(r1, address: "r", password: "", t: 1)])
        precondition(m.map(\.id) == [l1, r1], "remote-only appended after local")

        let tomb = synced(id, address: "a", password: "1", t: 300, deleted: true)
        precondition(SSHHostMerge.merged([local], [tomb])[0].host.deleted, "later tombstone wins")
        let day = 86400.0
        precondition(SSHHostMerge.pruned([tomb], now: at(300 + 29 * day)).count == 1, "fresh tombstone kept")
        precondition(SSHHostMerge.pruned([tomb], now: at(300 + 31 * day)).isEmpty, "old tombstone pruned")

        precondition(SSHHost(name: "", address: "h", username: "me").displayName == "me@h", "displayName fallback")
        precondition(SSHHost(name: "N", address: "h", username: "me").displayName == "N", "displayName name")

        func kh(_ hp: String, _ key: String, _ t: Double) -> KnownHost {
            KnownHost(hostPort: hp, keyType: "ssh-ed25519", fingerprintSHA256: "f", publicKey: key, addedAt: at(t))
        }
        let km = KnownHostMerge.merged([kh("a:22", "k1", 1), kh("b:22", "k2", 1)], [kh("a:22", "k3", 2), kh("c:22", "k4", 1)])
        precondition(km.map(\.hostPort) == ["a:22", "b:22", "c:22"] && km[0].publicKey == "k3", "known hosts union, later wins")
        precondition(KnownHostMerge.check(km, hostPort: "b:22", publicKey: "k2") == .trusted)
        precondition(KnownHostMerge.check(km, hostPort: "z:22", publicKey: "k") == .unknown)
        precondition(KnownHostMerge.check(km, hostPort: "b:22", publicKey: "other") == .changed(previous: km[1]))
        print("ssh merge: ok")
    }
}
