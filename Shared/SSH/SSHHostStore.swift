import Foundation
import Observation

/// Saved SSH hosts in a JSON file, their secrets in the keychain. Every change is saved at
/// once; `onLocalChange` fires for the user's own edits (not merges), like `BookmarkStore`.
@MainActor
@Observable
final class SSHHostStore {
    /// Everything, tombstones included (for sync). Views use `live`.
    private(set) var all: [SSHHost]

    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored let secrets: SSHSecretStore
    @ObservationIgnored var onLocalChange: (() -> Void)?

    /// `fileURL` nil keeps the hosts in memory only.
    init(fileURL: URL?, secrets: SSHSecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
        let saved = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([SSHHost].self, from: $0) }
        // Tombstones carry no secret, so pruning on the plain hosts is enough.
        all = (saved ?? []).filter { !$0.deleted || Date.now.timeIntervalSince($0.modifiedAt) < BookmarkMerge.tombstoneLifetime }
    }

    var live: [SSHHost] {
        all.filter { !$0.deleted }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func host(_ id: UUID) -> SSHHost? {
        all.first { $0.id == id && !$0.deleted }
    }

    func secret(for id: UUID) -> SSHSecret {
        secrets.read(id) ?? SSHSecret()
    }

    /// Adds the host or replaces the one with the same id in place. The secret goes to the
    /// keychain first: if that throws, nothing is stored and nothing is announced.
    func save(_ host: SSHHost, secret: SSHSecret) throws {
        var host = host
        host.modifiedAt = .now
        host.deleted = false
        try secrets.write(secret, for: host.id)
        if let index = all.firstIndex(where: { $0.id == host.id }) {
            all[index] = host
        } else {
            all.append(host)
        }
        changed()
    }

    func delete(_ id: UUID) {
        guard let index = all.firstIndex(where: { $0.id == id }), !all[index].deleted else { return }
        all[index].deleted = true
        all[index].modifiedAt = .now
        secrets.delete(id)
        changed()
    }

    // MARK: - Sync

    func synced() -> [SyncedSSHHost] {
        all.map { SyncedSSHHost(host: $0, secret: $0.deleted ? SSHSecret() : secret(for: $0.id)) }
    }

    /// Merges the other device's list (later `modifiedAt` wins per id, secret with it).
    /// Returns whether anything here changed.
    @discardableResult
    func merge(_ remote: [SyncedSSHHost]) -> Bool {
        let local = synced()
        let result = SSHHostMerge.pruned(SSHHostMerge.merged(local, remote), now: .now)
        guard result != local else { return false }
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var adopted: [SyncedSSHHost] = []
        for item in result {
            guard localByID[item.id] != item else { adopted.append(item); continue }
            if item.host.deleted {
                secrets.delete(item.id)
            } else if (try? secrets.write(item.secret, for: item.id)) == nil {
                // Keychain refused: keep our version so host and secret stay one winner's.
                if let mine = localByID[item.id] { adopted.append(mine) }
                continue
            }
            adopted.append(item)
        }
        for item in local where !adopted.contains(where: { $0.id == item.id }) { secrets.delete(item.id) }
        guard adopted != local else { return false }
        all = adopted.map(\.host)
        save()
        return true
    }

    // MARK: - Private

    private func changed() {
        save()
        onLocalChange?()
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
