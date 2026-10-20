import Foundation

/// One host's command lines on this device (`ssh-history/<host-id>.json`), never synced: newest last,
/// unique, at most 2000. Read and saved in the background; empty until read.
@MainActor
final class CommandHistory {
    nonisolated static let limit = 2000

    private var lines: [String] = []
    let fileURL: URL?
    /// Until the file is read; saving waits for it, so lines added meanwhile don't replace the file's.
    private var loading: Task<Void, Never>?
    private static let writes = DispatchQueue(label: "app.unibrowser.ssh-history", qos: .utility)

    /// `fileURL` nil keeps the history in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        guard let fileURL else { return }
        loading = Task { [weak self] in
            let saved = await Task.detached(priority: .utility) {
                (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            }.value
            guard let self else { return }
            let added = lines
            lines = saved.filter { !added.contains($0) } + added
            if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
            loading = nil
            if !added.isEmpty { save() }
        }
    }

    /// A host's history: `<directory>/<host-id>.json`, or memory only in private mode,
    /// which must never write typed commands to disk.
    convenience init(hostID: UUID, directory: URL, isPrivate: Bool) {
        self.init(fileURL: isPrivate ? nil : directory.appending(path: "\(hostID.uuidString.lowercased()).json"))
    }

    /// For checks.
    func loaded() async { await loading?.value }

    /// Lines starting with a space, and blank ones, are not kept.
    func add(_ line: String) {
        guard line.first != " ", !line.allSatisfy(\.isWhitespace) else { return }
        lines.removeAll { $0 == line }
        lines.append(line)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
        if loading == nil { save() }
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(lines) else { return }
        Self.writes.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Newest first.
    func matches(prefix: String, limit: Int) -> [String] {
        Array(lines.reversed().lazy.filter { $0.hasPrefix(prefix) }.prefix(limit))
    }

    /// Waits for pending saves (for checks).
    func flush() { Self.writes.sync {} }
}
