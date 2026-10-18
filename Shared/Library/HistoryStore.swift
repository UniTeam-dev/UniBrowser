import Foundation
import Observation
import SQLite3

/// One page visit. The same URL within 30 minutes on the same device is one visit.
struct Visit: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var url: URL
    var title: String
    var visitedAt: Date
    /// The device that made the visit (`BrowserStore.deviceID` / `MobileStore.deviceID`).
    var deviceID: String

    var host: String { url.host() ?? "" }
}

/// Where a profile's library files live: Application Support/UniBrowser/.
enum LibraryFiles {
    static func url(_ name: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "UniBrowser", directoryHint: .isDirectory).appending(path: name)
    }
}

/// Visit history of one profile in SQLite (system libsqlite3) with an FTS5
/// index over title and URL. Synchronous and main-actor: at a browser's
/// history size every call takes well under a millisecond.
@MainActor
@Observable
final class HistoryStore {
    static let dedupeWindow: TimeInterval = 30 * 60

    /// Bumped on every change, so a view showing history knows to query again.
    private(set) var revision = 0

    @ObservationIgnored let deviceID: String
    @ObservationIgnored private var db: OpaquePointer?

    /// `fileURL` nil keeps the history in memory only.
    init(fileURL: URL?, deviceID: String) {
        self.deviceID = deviceID
        guard let fileURL else {
            db = Self.open(":memory:")
            return
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let db = Self.open(fileURL.path) {
            self.db = db
        } else {
            // Unreadable file: keep it aside for inspection and start a fresh one.
            let aside = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            db = Self.open(fileURL.path) ?? Self.open(":memory:")
        }
    }

    private static let columns = "id, url, title, visitedAt, deviceID"

    private static func open(_ path: String) -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        let schema = """
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS visits(id TEXT PRIMARY KEY, url TEXT NOT NULL, title TEXT NOT NULL,
                host TEXT NOT NULL, visitedAt REAL NOT NULL, deviceID TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS visits_time ON visits(visitedAt);
            CREATE INDEX IF NOT EXISTS visits_url ON visits(url, visitedAt);
            CREATE INDEX IF NOT EXISTS visits_host ON visits(host);
            CREATE VIRTUAL TABLE IF NOT EXISTS visits_fts USING fts5(title, url, content='visits', content_rowid='rowid');
            CREATE TRIGGER IF NOT EXISTS visits_ai AFTER INSERT ON visits BEGIN
                INSERT INTO visits_fts(rowid, title, url) VALUES (new.rowid, new.title, new.url);
            END;
            CREATE TRIGGER IF NOT EXISTS visits_ad AFTER DELETE ON visits BEGIN
                INSERT INTO visits_fts(visits_fts, rowid, title, url) VALUES ('delete', old.rowid, old.title, old.url);
            END;
            CREATE TRIGGER IF NOT EXISTS visits_au AFTER UPDATE ON visits BEGIN
                INSERT INTO visits_fts(visits_fts, rowid, title, url) VALUES ('delete', old.rowid, old.title, old.url);
                INSERT INTO visits_fts(rowid, title, url) VALUES (new.rowid, new.title, new.url);
            END;
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    // MARK: - Recording

    /// Only web pages: not about:, data:, blob:, file: and the like.
    static func isRecordable(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    /// A finished main-frame load. The same URL on this device within 30
    /// minutes moves that visit to `time` (and takes a non-empty title).
    func record(url: URL, title: String, at time: Date = .now) {
        guard Self.isRecordable(url) else { return }
        let link = url.absoluteString
        if let existing = first("SELECT id FROM visits WHERE url = ? AND deviceID = ? AND visitedAt >= ? ORDER BY visitedAt DESC LIMIT 1",
                                [link, deviceID, time.timeIntervalSince1970 - Self.dedupeWindow]) {
            run("UPDATE visits SET visitedAt = max(visitedAt, ?), title = CASE WHEN ? = '' THEN title ELSE ? END WHERE id = ?",
                [time.timeIntervalSince1970, title, title, existing])
        } else {
            insert(Visit(id: UUID(), url: url, title: title, visitedAt: time, deviceID: deviceID))
        }
        revision += 1
    }

    /// The page's title arrived or changed after the load: the latest visit of `url` takes it.
    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, Self.isRecordable(url) else { return }
        run("""
            UPDATE visits SET title = ? WHERE id = (SELECT id FROM visits WHERE url = ? AND deviceID = ?
                ORDER BY visitedAt DESC LIMIT 1) AND title != ?
            """, [title, url.absoluteString, deviceID, title])
        if sqlite3_changes(db) > 0 { revision += 1 }
    }

    // MARK: - Reading

    /// Prefix match on every word over title and URL; newest first, one row per
    /// URL (its latest visit). An empty query lists the most recent pages.
    func search(_ query: String, limit: Int) -> [Visit] {
        let words = query.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        if words.isEmpty {
            guard query.allSatisfy(\.isWhitespace) else { return [] }
            return visits("SELECT \(Self.columns), max(visitedAt) FROM visits GROUP BY url ORDER BY visitedAt DESC LIMIT ?", [limit])
        }
        return visits("""
            SELECT \(Self.columns), max(visitedAt) FROM visits
            WHERE rowid IN (SELECT rowid FROM visits_fts WHERE visits_fts MATCH ?)
            GROUP BY url ORDER BY visitedAt DESC LIMIT ?
            """, [words.joined(separator: " "), limit])
    }

    /// Every visit of that local calendar day, newest first.
    func visits(on day: Date) -> [Visit] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return visits("SELECT \(Self.columns) FROM visits WHERE visitedAt >= ? AND visitedAt < ? ORDER BY visitedAt DESC",
                      [start.timeIntervalSince1970, end.timeIntervalSince1970])
    }

    /// Local days that have visits (start of day), newest first.
    func days(limit: Int) -> [Date] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return strings("SELECT DISTINCT date(visitedAt, 'unixepoch', 'localtime') AS day FROM visits ORDER BY day DESC LIMIT ?", [limit])
            .compactMap { formatter.date(from: $0).map { Calendar.current.startOfDay(for: $0) } }
    }

    /// Visits made or moved after `date`, oldest first (what sync sends).
    func visits(since date: Date) -> [Visit] {
        visits("SELECT \(Self.columns) FROM visits WHERE visitedAt > ? ORDER BY visitedAt", [date.timeIntervalSince1970])
    }

    // MARK: - Deleting

    func delete(ids: [UUID]) {
        transaction { for id in ids { run("DELETE FROM visits WHERE id = ?", [id.uuidString]) } }
    }

    /// The site and its subdomains.
    func delete(host: String) {
        let host = host.lowercased()
        changing("DELETE FROM visits WHERE host = ? OR host LIKE ? ESCAPE '\\'",
                 [host, "%." + host.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")])
    }

    func delete(since date: Date) {
        changing("DELETE FROM visits WHERE visitedAt >= ?", [date.timeIntervalSince1970])
    }

    func deleteAll() {
        changing("DELETE FROM visits", [])
    }

    func prune(olderThan days: Int = 90) {
        changing("DELETE FROM visits WHERE visitedAt < ?", [Date.now.timeIntervalSince1970 - Double(days) * 86400])
    }

    // MARK: - Sync

    /// Visits from the other device: new ids are added, a known id takes a later time and title.
    func merge(_ remote: [Visit]) {
        guard !remote.isEmpty else { return }
        transaction {
            for visit in remote {
                run("""
                    INSERT INTO visits(id, url, title, host, visitedAt, deviceID) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET visitedAt = excluded.visitedAt, title = excluded.title
                    WHERE excluded.visitedAt > visits.visitedAt
                    """, Self.row(visit))
            }
        }
    }

    // MARK: - SQLite

    private static func row(_ visit: Visit) -> [Any] {
        [visit.id.uuidString, visit.url.absoluteString, visit.title, visit.host.lowercased(),
         visit.visitedAt.timeIntervalSince1970, visit.deviceID]
    }

    private func insert(_ visit: Visit) {
        run("INSERT OR IGNORE INTO visits(id, url, title, host, visitedAt, deviceID) VALUES (?, ?, ?, ?, ?, ?)", Self.row(visit))
    }

    private func changing(_ sql: String, _ arguments: [Any]) {
        run(sql, arguments)
        revision += 1
    }

    private func transaction(_ body: () -> Void) {
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        body()
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        revision += 1
    }

    /// Runs `body` for each result row; false if the statement didn't prepare.
    @discardableResult
    private func query(_ sql: String, _ arguments: [Any], _ body: (OpaquePointer) -> Void = { _ in }) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let text as String: sqlite3_bind_text(statement, index, text, -1, transient)
            case let number as Double: sqlite3_bind_double(statement, index, number)
            case let number as Int: sqlite3_bind_int64(statement, index, Int64(number))
            default: sqlite3_bind_null(statement, index)
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW { body(statement) }
        return true
    }

    private func run(_ sql: String, _ arguments: [Any]) {
        query(sql, arguments)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private func strings(_ sql: String, _ arguments: [Any]) -> [String] {
        var out: [String] = []
        query(sql, arguments) { out.append(text($0, 0)) }
        return out
    }

    private func first(_ sql: String, _ arguments: [Any]) -> String? {
        strings(sql, arguments).first
    }

    private func visits(_ sql: String, _ arguments: [Any]) -> [Visit] {
        var out: [Visit] = []
        query(sql, arguments) { row in
            guard let id = UUID(uuidString: text(row, 0)), let url = URL(string: text(row, 1)) else { return }
            out.append(Visit(id: id, url: url, title: text(row, 2),
                             visitedAt: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)), deviceID: text(row, 4)))
        }
        return out
    }
}
