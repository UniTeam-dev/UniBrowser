import Foundation
import SQLite3

/// A bookmark read from another browser. `folderPath` is outermost first, e.g. ["Панель закладок", "Работа"].
struct ImportedBookmark: Hashable, Sendable {
    var title: String
    var url: URL
    var folderPath: [String]
    var addedAt: Date?
}

/// One visit read from another browser's history.
struct ImportedVisit: Hashable, Sendable {
    var title: String
    var url: URL
    var visitedAt: Date
}

struct ImportError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Readers for other browsers' data. Pure functions, no app state: checked by scripts/import_check.swift.
enum BrowserImport {
    /// Web pages only: no javascript: bookmarklets, chrome:// or about: pages.
    static func isImportable(_ url: URL) -> Bool {
        ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "")
    }

    // MARK: - Chrome bookmarks (JSON)

    /// Chrome's `Bookmarks` file: `{"roots": {"bookmark_bar": node, "other": node, "synced": node}}`,
    /// a node being `{"type": "url"|"folder", "name", "url", "date_added", "children"}`.
    static func chromeBookmarks(json data: Data) -> [ImportedBookmark] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return [] }
        var result: [ImportedBookmark] = []
        func walk(_ node: [String: Any], path: [String]) {
            let name = node["name"] as? String ?? ""
            if node["type"] as? String == "url" {
                guard let string = node["url"] as? String, let url = URL(string: string), isImportable(url) else { return }
                let added = (node["date_added"] as? String).flatMap(Int64.init).map(chromeDate)
                result.append(ImportedBookmark(title: name.isEmpty ? (url.host() ?? string) : name, url: url, folderPath: path, addedAt: added))
            } else {
                for child in node["children"] as? [[String: Any]] ?? [] { walk(child, path: path + [name]) }
            }
        }
        let titles = ["bookmark_bar": "Панель закладок", "other": "Другие закладки", "synced": "Мобильные закладки"]
        for key in ["bookmark_bar", "other", "synced"] {
            guard let node = roots[key] as? [String: Any] else { continue }
            for child in node["children"] as? [[String: Any]] ?? [] { walk(child, path: [titles[key]!]) }
        }
        return result
    }

    /// Chrome's timestamps: microseconds since 1601-01-01 UTC.
    static func chromeDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    static func chromeMicroseconds(_ date: Date) -> Double {
        (date.timeIntervalSince1970 + 11_644_473_600) * 1_000_000
    }

    // MARK: - Netscape bookmarks (HTML)

    /// The `<DL><DT><H3>Folder</H3><DL>…<DT><A HREF=… ADD_DATE=…>Title</A>…</DL>` file that
    /// Safari («Файл → Экспорт → Закладки…»), Chrome, Firefox and Edge all export.
    static func netscapeBookmarks(html: String) -> [ImportedBookmark] {
        let pattern = #"<DL\b[^>]*>|</DL\s*>|<H3\b[^>]*>(.*?)</H3\s*>|<A\b([^>]*)>(.*?)</A\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let text = html as NSString
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : text.substring(with: range)
        }
        var stack: [String?] = [] // one entry per open <DL>; nil for the file's outer list
        var pendingFolder: String?
        var result: [ImportedBookmark] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let tag = text.substring(with: match.range).prefix(3).uppercased()
            if let folder = group(match, 1) {
                pendingFolder = decodeEntities(stripTags(folder)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let attributes = group(match, 2), let title = group(match, 3) {
                guard let href = attribute("HREF", in: attributes), let url = URL(string: decodeEntities(href)), isImportable(url) else { continue }
                let added = attribute("ADD_DATE", in: attributes).flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
                let name = decodeEntities(stripTags(title)).trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(ImportedBookmark(title: name.isEmpty ? (url.host() ?? url.absoluteString) : name, url: url,
                                               folderPath: stack.compactMap { $0 }, addedAt: added))
            } else if tag.hasPrefix("</D") {
                _ = stack.popLast()
            } else if tag.hasPrefix("<DL") {
                stack.append(pendingFolder)
                pendingFolder = nil
            }
        }
        return result
    }

    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = "\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length))
        else { return nil }
        for index in 1...3 where match.range(at: index).location != NSNotFound {
            return (attributes as NSString).substring(with: match.range(at: index))
        }
        return nil
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.prefix(10).firstIndex(of: ";") {
                let entity = after[..<semicolon]
                var decoded: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    decoded = named[String(entity).lowercased()]
                }
                if let decoded {
                    result += decoded
                    rest = after[after.index(after: semicolon)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }

    // MARK: - History (SQLite)

    /// Chrome's `History`: `visits.visit_time` (Chrome time) joined to `urls`. Newest first.
    static func chromeHistory(databaseAt url: URL, since: Date) throws -> [ImportedVisit] {
        try visits(in: url, sql: """
            SELECT urls.url, urls.title, visits.visit_time FROM visits JOIN urls ON urls.id = visits.url
            WHERE visits.visit_time > ? ORDER BY visits.visit_time DESC LIMIT 200000
            """, since: chromeMicroseconds(since), date: { chromeDate(Int64($0)) })
    }

    /// Safari's `History.db`: `history_visits.visit_time` (seconds since 2001) joined to `history_items`. Newest first.
    static func safariHistory(databaseAt url: URL, since: Date) throws -> [ImportedVisit] {
        try visits(in: url, sql: """
            SELECT history_items.url, history_visits.title, history_visits.visit_time FROM history_visits
            JOIN history_items ON history_items.id = history_visits.history_item
            WHERE history_visits.visit_time > ? ORDER BY history_visits.visit_time DESC LIMIT 200000
            """, since: since.timeIntervalSinceReferenceDate, date: { Date(timeIntervalSinceReferenceDate: $0) })
    }

    private static func visits(in url: URL, sql: String, since: Double, date: (Double) -> Date) throws -> [ImportedVisit] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ImportError("Не удалось открыть историю: \(String(cString: sqlite3_errmsg(db)))")
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError("Не удалось прочитать историю: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_bind_double(statement, 1, since)
        var result: [ImportedVisit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_text(statement, 0), let url = URL(string: String(cString: raw)), isImportable(url) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            result.append(ImportedVisit(title: title, url: url, visitedAt: date(sqlite3_column_double(statement, 2))))
        }
        return result
    }

    /// Copies a database (and its -wal/-shm/-journal) into a new temporary folder, so the
    /// running browser's lock and its unflushed WAL don't get in the way. Delete the folder after.
    static func temporaryCopy(of database: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "UniBrowserImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: database.lastPathComponent)
        try FileManager.default.copyItem(at: database, to: copy)
        for suffix in ["-wal", "-shm", "-journal"] {
            let sibling = URL(filePath: database.path(percentEncoded: false) + suffix)
            try? FileManager.default.copyItem(at: sibling, to: URL(filePath: copy.path(percentEncoded: false) + suffix))
        }
        return copy
    }

    /// Reads a history database through a temporary copy, removing the copy afterwards.
    static func readCopy(of database: URL, _ read: (URL) throws -> [ImportedVisit]) throws -> [ImportedVisit] {
        let copy = try temporaryCopy(of: database)
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        return try read(copy)
    }

    // MARK: - Where the browsers keep it

    static let home = URL(filePath: NSHomeDirectory())
    static let chromeFolder = home.appending(path: "Library/Application Support/Google/Chrome", directoryHint: .isDirectory)
    static let safariHistory = home.appending(path: "Library/Safari/History.db")

    struct ChromeProfile: Hashable, Identifiable {
        let folder: URL
        let name: String
        var id: URL { folder }
        var bookmarks: URL { folder.appending(path: "Bookmarks") }
        var history: URL { folder.appending(path: "History") }
    }

    /// Chrome's profiles with their display names from `Local State`; Default first.
    static func chromeProfiles(in root: URL = chromeFolder) -> [ChromeProfile] {
        let names = (try? Data(contentsOf: root.appending(path: "Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] } ?? [:]
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        return folders
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .map { root.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "Bookmarks").path(percentEncoded: false))
                || FileManager.default.fileExists(atPath: $0.appending(path: "History").path(percentEncoded: false)) }
            .map { ChromeProfile(folder: $0, name: names[$0.lastPathComponent]?["name"] as? String ?? $0.lastPathComponent) }
            .sorted { ($0.folder.lastPathComponent == "Default" ? "" : $0.folder.lastPathComponent) < ($1.folder.lastPathComponent == "Default" ? "" : $1.folder.lastPathComponent) }
    }

    /// Safari's history is behind «Полный доступ к диску»: without it, opening the file fails with EPERM.
    static func canRead(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }

    /// System Settings → Privacy & Security → Full Disk Access.
    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
