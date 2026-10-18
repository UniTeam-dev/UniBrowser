// Self-check for UniBrowser/Import/BrowserImport.swift:
//   swiftc -parse-as-library UniBrowser/Import/BrowserImport.swift scripts/import_check.swift -o /tmp/import_check && /tmp/import_check
import Foundation
import SQLite3

@main
enum ImportCheck {
    static func main() throws {
        checkChromeBookmarks()
        checkNetscape()
        checkEntities()
        try checkChromeHistory()
        try checkSafariHistory()
        print("import_check: OK")
    }

    static func checkChromeBookmarks() {
        let json = """
        {"roots": {
          "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
            {"type": "url", "name": "Example", "url": "https://example.com/", "date_added": "13300000000000000"},
            {"type": "folder", "name": "Работа", "children": [
              {"type": "url", "name": "", "url": "https://work.example/a?b=1"},
              {"type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)"}
            ]}
          ]},
          "other": {"type": "folder", "name": "Other", "children": [
            {"type": "url", "name": "Other one", "url": "http://other.example"}
          ]},
          "synced": {"type": "folder", "name": "Mobile", "children": []}
        }, "version": 1}
        """
        let items = BrowserImport.chromeBookmarks(json: Data(json.utf8))
        assert(items.count == 3, "chrome: expected 3, got \(items.count)")
        assert(items[0].title == "Example" && items[0].folderPath == ["Панель закладок"])
        // 13300000000000000 µs after 1601 = 2022-06-18T…; check the year only.
        let year = Calendar(identifier: .gregorian).component(.year, from: items[0].addedAt!)
        assert(year == 2022, "chrome date: \(items[0].addedAt!)")
        assert(items[1].folderPath == ["Панель закладок", "Работа"] && items[1].title == "work.example", "\(items[1])")
        assert(items[2].folderPath == ["Другие закладки"] && items[2].url.absoluteString == "http://other.example")
        assert(BrowserImport.chromeBookmarks(json: Data("nope".utf8)).isEmpty)
    }

    static func checkNetscape() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Избранное</H3>
            <DL><p>
                <DT><A HREF="https://a.example/?x=1&amp;y=2" ADD_DATE="1700000001">A &amp; B</A>
                <DT><H3>Deep</H3>
                <DL><p>
                    <DT><a href='https://deep.example'>Deep &#8212; one &#x41;</a>
                </DL><p>
            </DL><p>
            <DT><A HREF="https://top.example">Top</A>
            <DT><A HREF="place:sort=8">Firefox smart folder</A>
            <DT><H3>Empty</H3>
            <DL><p>
            </DL><p>
            <DT><A HREF="https://after.example">After</A>
        </DL><p>
        """
        let items = BrowserImport.netscapeBookmarks(html: html)
        assert(items.count == 4, "netscape: expected 4, got \(items.count): \(items)")
        assert(items[0].url.absoluteString == "https://a.example/?x=1&y=2" && items[0].title == "A & B")
        assert(items[0].folderPath == ["Избранное"] && items[0].addedAt == Date(timeIntervalSince1970: 1_700_000_001))
        assert(items[1].folderPath == ["Избранное", "Deep"] && items[1].title == "Deep — one A", "\(items[1])")
        assert(items[2].folderPath == [] && items[2].title == "Top")
        assert(items[3].folderPath == [] && items[3].title == "After", "folder stack must unwind: \(items[3])")
    }

    static func checkEntities() {
        assert(BrowserImport.decodeEntities("a &lt;b&gt; &unknown; & c &#39;") == "a <b> &unknown; & c '")
    }

    static func makeDB(_ statements: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "import_check-\(UUID().uuidString).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw ImportError("open") }
        defer { sqlite3_close(db) }
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ImportError(String(cString: sqlite3_errmsg(db))) }
        }
        return url
    }

    static func checkChromeHistory() throws {
        let now = Date()
        let recent = Int64(BrowserImport.chromeMicroseconds(now.addingTimeInterval(-3600)))
        let old = Int64(BrowserImport.chromeMicroseconds(now.addingTimeInterval(-200 * 86400)))
        let db = try makeDB([
            "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT)",
            "CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)",
            "INSERT INTO urls VALUES (1, 'https://recent.example/', 'Recent'), (2, 'https://old.example/', 'Old'), (3, 'chrome://settings', 'Settings')",
            "INSERT INTO visits VALUES (1, 1, \(recent)), (2, 2, \(old)), (3, 3, \(recent)), (4, 1, \(recent - 1000000))",
        ])
        // Read through the temporary copy, as the app does; the copy's folder is removed after.
        let visits = try BrowserImport.readCopy(of: db) { try BrowserImport.chromeHistory(databaseAt: $0, since: now.addingTimeInterval(-90 * 86400)) }
        assert(visits.count == 2, "chrome history: expected 2, got \(visits)")
        assert(visits.allSatisfy { $0.url.host() == "recent.example" && $0.title == "Recent" })
        assert(visits[0].visitedAt > visits[1].visitedAt, "newest first")
        assert(abs(visits[0].visitedAt.timeIntervalSince(now.addingTimeInterval(-3600))) < 1, "chrome time conversion")
        try FileManager.default.removeItem(at: db)
    }

    static func checkSafariHistory() throws {
        let now = Date()
        let db = try makeDB([
            "PRAGMA journal_mode=WAL",
            "CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT)",
            "CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT)",
            "INSERT INTO history_items VALUES (1, 'https://safari.example/page')",
            "INSERT INTO history_visits VALUES (1, 1, \(now.timeIntervalSinceReferenceDate - 60), 'Страница'), (2, 1, \(now.timeIntervalSinceReferenceDate - 120), NULL)",
        ])
        let visits = try BrowserImport.readCopy(of: db) { try BrowserImport.safariHistory(databaseAt: $0, since: .distantPast) }
        assert(visits.count == 2 && visits[0].title == "Страница" && visits[1].title == "", "\(visits)")
        assert(abs(visits[0].visitedAt.timeIntervalSince(now.addingTimeInterval(-60))) < 1)
        assert(!BrowserImport.canRead(URL(filePath: "/nonexistent/History.db")))
        assert(BrowserImport.canRead(db))
        try FileManager.default.removeItem(at: db)
    }
}
