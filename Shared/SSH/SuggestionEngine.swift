import Foundation

struct Suggestion: Hashable {
    enum Kind { case history, command, path }
    var kind: Kind
    var display: String
    /// The suffix to type.
    var insert: String
}

/// Completions for an SSH tab's input line: this host's history, then the server's commands for the
/// first word or SFTP listings for later words.
@MainActor
final class SuggestionEngine {
    static let limit = 8
    nonisolated static let commandsLifetime: TimeInterval = 24 * 60 * 60

    let history: CommandHistory
    private let session: SSHSession
    private let browser: SFTPBrowser
    private let commandsCacheURL: URL?
    /// Shortest first, so `ls` comes before `last` for `l`; empty until loaded, and when the server gave none.
    private var commands: [String] = []
    private var home: String?

    init(session: SSHSession, browser: SFTPBrowser, history: CommandHistory, commandsCacheURL: URL?) {
        self.session = session
        self.browser = browser
        self.history = history
        self.commandsCacheURL = commandsCacheURL
    }

    /// `compgen -c` (bash; sorted here), else `ls` over each `$PATH` dir; cached on disk for 24 h.
    /// Failures leave the list as it is.
    func loadCommands() async {
        let url = commandsCacheURL
        if let cached = await Task.detached(operation: { Self.readCache(url) }).value {
            commands = Self.ranked(cached)
            return
        }
        let output: String
        do {
            output = try await session.exec("compgen -c")
        } catch {
            guard let fallback = try? await session.exec(#"sh -c 'IFS=:; for d in $PATH; do ls "$d"; done 2>/dev/null; true'"#) else { return }
            output = fallback
        }
        let list = Set(output.split(separator: "\n").map(String.init)).sorted()
        guard !list.isEmpty else { return }
        commands = Self.ranked(list)
        guard let url else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(list).write(to: url, options: .atomic)
        }
    }

    private static func ranked(_ list: [String]) -> [String] { list.sorted { ($0.count, $0) < ($1.count, $1) } }

    nonisolated private static func readCache(_ url: URL?) -> [String]? {
        // Not `resourceValues`: a URL caches those, and the engine keeps its URL across reconnects.
        guard let url, let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              Date.now.timeIntervalSince(modified) < commandsLifetime, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// At most 8, without repeats: history lines that extend the whole line, then commands for the first
    /// word or paths for later ones. `cwd` resolves relative paths.
    func suggestions(for model: CommandLineModel, cwd: String?) async -> [Suggestion] {
        guard model.showsSuggestions, let line = model.line else { return [] }
        var result = history.matches(prefix: line, limit: Self.limit + 1)
            .filter { $0 != line }
            .map { Suggestion(kind: .history, display: $0, insert: String($0.dropFirst(line.count))) }
        let (word, isFirst) = model.currentWord
        if isFirst, !word.isEmpty {
            result += commands.lazy.filter { $0.hasPrefix(word) && $0 != word }.prefix(Self.limit)
                .map { Suggestion(kind: .command, display: $0, insert: String($0.dropFirst(word.count))) }
        } else if !isFirst, !word.hasPrefix("-") {
            result += await paths(word, cwd: cwd)
        }
        var seen = Set<String>()
        return Array(result.filter { seen.insert($0.insert).inserted }.prefix(Self.limit))
    }

    /// Entries of the word's folder whose names extend it, folders with a trailing `/`, the suffix quoted
    /// the way the word is. Names with control characters are left out: their suffix would run as keystrokes.
    private func paths(_ word: String, cwd: String?) async -> [Suggestion] {
        guard !word.isEmpty, let (value, quote) = CommandLineModel.unquoted(word) else { return [] }
        let slash = value.lastIndex(of: "/")
        let folder = slash.map { String(value[...$0]) } ?? ""
        let prefix = slash.map { String(value[value.index(after: $0)...]) } ?? value
        let dir: String
        if folder.hasPrefix("/") {
            dir = folder
        } else if folder.hasPrefix("~/") {
            guard let home = await homeDirectory() else { return [] }
            dir = home + folder.dropFirst()
        } else if let cwd, !value.hasPrefix("~") {
            dir = cwd.hasSuffix("/") ? cwd + folder : cwd + "/" + folder
        } else {
            return []
        }
        guard let entries = try? await browser.listing(dir) else { return [] }
        return entries
            .filter { $0.name.hasPrefix(prefix) && (prefix.hasPrefix(".") || !$0.name.hasPrefix(".")) }
            .filter { !$0.name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }
            .sorted { $0.name < $1.name }
            .map { entry in
                let rest = String(entry.name.dropFirst(prefix.count)) + (entry.isDirectory ? "/" : "")
                return Suggestion(kind: .path, display: entry.name + (entry.isDirectory ? "/" : ""),
                                  insert: CommandLineModel.escaped(rest, quote: quote))
            }
            .filter { !$0.insert.isEmpty }
    }

    private func homeDirectory() async -> String? {
        if home == nil { home = try? await session.exec(#"printf %s "$HOME""#) }
        return home
    }
}
