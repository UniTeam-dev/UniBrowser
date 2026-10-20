import Foundation
import Observation

/// Server keys the user has trusted, in a JSON file. Same change rules as `BookmarkStore`.
@MainActor
@Observable
final class KnownHostsStore {
    private(set) var all: [KnownHost]

    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored var onLocalChange: (() -> Void)?

    /// `fileURL` nil keeps the keys in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        all = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([KnownHost].self, from: $0) } ?? []
    }

    func check(hostPort: String, publicKey: String) -> KnownHostCheck {
        KnownHostMerge.check(all, hostPort: hostPort, publicKey: publicKey)
    }

    /// Remembers the key, replacing the one for the same `hostPort`.
    func trust(_ key: KnownHost) {
        all.removeAll { $0.hostPort == key.hostPort }
        all.append(key)
        save()
        onLocalChange?()
    }

    @discardableResult
    func merge(_ remote: [KnownHost]) -> Bool {
        let result = KnownHostMerge.merged(all, remote)
        guard result != all else { return false }
        all = result
        save()
        return true
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
