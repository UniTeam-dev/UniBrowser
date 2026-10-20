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

    /// Adds the host or replaces the one with the same id in place.
    func save(_ host: SSHHost, secret: SSHSecret) {
        var host = host
        host.modifiedAt = .now
        host.deleted = false
        try? secrets.write(secret, for: host.id)
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
        for item in result where localByID[item.id] != item {
            if item.host.deleted { secrets.delete(item.id) } else { try? secrets.write(item.secret, for: item.id) }
        }
        for item in local where !result.contains(where: { $0.id == item.id }) { secrets.delete(item.id) }
        all = result.map(\.host)
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
