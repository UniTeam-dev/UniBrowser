// Checks the SSH host store (file + keychain) and the known-hosts store. Uses the keychain
// service app.unibrowser.ssh.check and a temp directory, and removes both at the end.
//   swiftc -parse-as-library Shared/Library/BookmarkMerge.swift Shared/SSH/SSHHost.swift Shared/SSH/SSHSecretStore.swift Shared/SSH/SSHHostStore.swift Shared/SSH/KnownHostsStore.swift scripts/ssh_store_check.swift -o /tmp/ssh_store_check && /tmp/ssh_store_check
import Foundation

@main
@MainActor
struct SSHStoreCheck {
    static func main() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ssh-store-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = SSHSecretStore(service: "app.unibrowser.ssh.check")
        let hostsFile = dir.appending(path: "ssh-hosts.json")
        var ids: [UUID] = []
        defer { ids.forEach(secrets.delete) }

        // save -> reload
        let store = SSHHostStore(fileURL: hostsFile, secrets: secrets)
        var changes = 0
        store.onLocalChange = { changes += 1 }
        let host = SSHHost(name: "nas", address: "192.168.1.5", username: "ilya")
        ids.append(host.id)
        let secret = SSHSecret(password: "pw1")
        try! store.save(host, secret: secret)
        precondition(changes == 1)
        let other = SSHHost(name: "a-first", address: "x", username: "u")
        ids.append(other.id)
        try! store.save(other, secret: SSHSecret())
        try! store.save(SSHHost(id: host.id, name: "nas2", address: "192.168.1.5", username: "ilya"), secret: secret)
        precondition(store.all.map(\.id) == [host.id, other.id], "save replaces in place")
        precondition(store.live.map(\.name) == ["a-first", "nas2"], "live sorted by name")
        let reloaded = SSHHostStore(fileURL: hostsFile, secrets: secrets)
        precondition(reloaded.host(host.id) == store.host(host.id) && reloaded.host(host.id) != nil)
        precondition(reloaded.secret(for: host.id) == secret, "secret round-trip")
        precondition(reloaded.secret(for: UUID()) == SSHSecret(), "missing secret is empty")

        // merge
        let current = store.synced().first { $0.id == host.id }!
        precondition(store.merge(store.synced()) == false, "identical merge")
        var newer = current
        newer.host.modifiedAt = current.host.modifiedAt.addingTimeInterval(10)
        newer.secret = SSHSecret(password: "pw2")
        let before = changes
        precondition(store.merge([newer]), "newer remote wins")
        precondition(changes == before, "merge is not a local change")
        precondition(secrets.read(host.id)?.password == "pw2", "merge writes keychain")

        // delete
        store.delete(host.id)
        store.delete(other.id)
        precondition(store.live.isEmpty && store.all.count == 2, "tombstones kept")
        precondition(secrets.read(host.id) == nil, "keychain emptied")

        // remote-only host is appended with its secret; a remote tombstone clears the keychain
        let fresh = SyncedSSHHost(host: SSHHost(name: "new", address: "y", username: "u"), secret: SSHSecret(password: "pw3"))
        ids.append(fresh.id)
        precondition(store.merge([fresh]) && store.all.contains { $0.id == fresh.id })
        precondition(secrets.read(fresh.id)?.password == "pw3", "remote-only secret stored")
        var gone = fresh
        gone.host.deleted = true
        gone.host.modifiedAt = fresh.host.modifiedAt.addingTimeInterval(10)
        gone.secret = SSHSecret()
        precondition(store.merge([gone]) && secrets.read(fresh.id) == nil && store.host(fresh.id) == nil, "remote tombstone")

        // a failing keychain: save throws and changes nothing; merge keeps the local version
        let broken = SSHHostStore(fileURL: nil, secrets: SSHSecretStore(service: "app.unibrowser.ssh.check", failsWrites: true))
        var brokenChanges = 0
        broken.onLocalChange = { brokenChanges += 1 }
        let h = SSHHost(address: "z", username: "u")
        precondition((try? broken.save(h, secret: SSHSecret(password: "x"))) == nil, "save throws")
        precondition(broken.all.isEmpty && brokenChanges == 0, "failed save changes nothing")
        precondition(broken.merge([SyncedSSHHost(host: h, secret: SSHSecret(password: "x"))]) == false && broken.all.isEmpty, "failed merge adopts nothing")

        // known hosts
        let knownFile = dir.appending(path: "known-hosts.json")
        let known = KnownHostsStore(fileURL: knownFile)
        let key = KnownHost(hostPort: "h:22", keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:x", publicKey: "AAAA", addedAt: .now)
        precondition(known.check(hostPort: "h:22", publicKey: "AAAA") == .unknown)
        known.trust(key)
        precondition(known.check(hostPort: "h:22", publicKey: "AAAA") == .trusted)
        precondition(KnownHostsStore(fileURL: knownFile).check(hostPort: "h:22", publicKey: "AAAA") == .trusted, "persisted")
        precondition(known.merge(known.all) == false)
        print("ssh store: ok")
    }
}
