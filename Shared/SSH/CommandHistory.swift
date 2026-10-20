import Foundation

/// One host's command lines on this device (`ssh-history/<host-id>.json`), never synced: newest last,
/// unique, at most 2000. Saved in the background after each `add`.
final class CommandHistory {
    static let limit = 2000

    private var lines: [String]
    private let fileURL: URL?
    private static let writes = DispatchQueue(label: "app.unibrowser.ssh-history", qos: .utility)

    /// `fileURL` nil keeps the history in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        lines = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
    }

    /// Lines starting with a space, and blank ones, are not kept.
    func add(_ line: String) {
        guard line.first != " ", !line.allSatisfy(\.isWhitespace) else { return }
        lines.removeAll { $0 == line }
        lines.append(line)
        if lines.count > Self.limit { lines.removeFirst(lines.count - Self.limit) }
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
