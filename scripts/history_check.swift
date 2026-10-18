// Self-check for Shared/Library/HistoryStore.swift (temp database):
//   swiftc -parse-as-library Shared/Library/HistoryStore.swift scripts/history_check.swift -o /tmp/history_check && /tmp/history_check
import Foundation

@main
enum HistoryCheck {
    nonisolated(unsafe) static var failed = false

    static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failed = true }
    }

    @MainActor
    static func main() {
        let file = FileManager.default.temporaryDirectory.appending(path: "history-check-\(UUID()).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: file.path + suffix) }
        }
        let store = HistoryStore(fileURL: file, deviceID: "mac")
        let now = Date.now
        let url = URL(string: "https://github.com/apple/swift")!

        // (a) Recording and the 30-minute window.
        store.record(url: url, title: "Swift", at: now.addingTimeInterval(-3600))
        store.record(url: url, title: "", at: now.addingTimeInterval(-3000))
        check("(a) same URL within 30 min updates the visit", store.visits(since: .distantPast).count == 1
              && store.visits(since: .distantPast)[0].visitedAt.timeIntervalSince(now) > -3001
              && store.visits(since: .distantPast)[0].title == "Swift")
        store.record(url: url, title: "Swift 6", at: now.addingTimeInterval(-60))
        check("(a) after 30 min it's a new visit", store.visits(since: .distantPast).count == 2)
        for skipped in ["about:blank", "data:text/html,hi", "file:///etc/hosts", "blob:https://a.example/1"] {
            store.record(url: URL(string: skipped)!, title: "x")
        }
        check("(a) about/data/file/blob are not recorded", store.visits(since: .distantPast).count == 2)

        store.record(url: URL(string: "https://habr.com/ru/articles/1")!, title: "Хабр: статья про Swift", at: now.addingTimeInterval(-30))
        store.record(url: URL(string: "https://www.apple.com/")!, title: "Apple", at: now.addingTimeInterval(-20))
        store.updateTitle(url: URL(string: "https://www.apple.com/")!, title: "Apple (Россия)")

        // (b) Search: prefix, title and URL, one row per URL, newest first.
        let swift = store.search("swi", limit: 10)
        check("(b) prefix search, one row per URL, newest first",
              swift.map(\.url.host) == ["habr.com", "github.com"] && swift[1].title == "Swift 6")
        check("(b) search by URL part", store.search("github", limit: 10).count == 1)
        check("(b) Cyrillic and case", store.search("ХАБР", limit: 10).count == 1)
        check("(b) several words AND", store.search("статья swift", limit: 10).count == 1 && store.search("статья apple", limit: 10).isEmpty)
        check("(b) title update is searchable", store.search("Россия", limit: 10).count == 1)
        check("(b) punctuation-only query is harmless", store.search("\"*-", limit: 10).isEmpty)
        check("(b) empty query lists recent", store.search("", limit: 2).map(\.url.host) == ["www.apple.com", "habr.com"])

        // (c) Days.
        check("(c) days", store.days(limit: 10).first == Calendar.current.startOfDay(for: now)
              && store.visits(on: now).count == store.visits(since: Calendar.current.startOfDay(for: now)).count)

        // (d) Merge: insert-or-ignore by id, newer time of a known id moves it.
        let remote = Visit(id: UUID(), url: URL(string: "https://example.org")!, title: "Remote", visitedAt: now.addingTimeInterval(-10), deviceID: "phone")
        store.merge([remote, remote])
        store.merge([remote])
        check("(d) merge inserts once", store.visits(since: .distantPast).filter { $0.id == remote.id }.count == 1)
        check("(d) merged visit keeps its device", store.search("Remote", limit: 1).first?.deviceID == "phone")
        store.record(url: remote.url, title: "Local", at: now)
        check("(d) the window doesn't swallow another device's visit", store.visits(since: .distantPast).filter { $0.url == remote.url }.count == 2)

        // (e) Delete by id, by host (with subdomains), by period, all.
        store.delete(ids: [remote.id])
        check("(e) delete ids", !store.visits(since: .distantPast).contains { $0.id == remote.id })
        store.record(url: URL(string: "https://gist.github.com/1")!, title: "Gist", at: now)
        store.delete(host: "github.com")
        check("(e) delete host incl. subdomains", !store.visits(since: .distantPast).contains { $0.url.host()?.hasSuffix("github.com") == true }
              && store.search("swift", limit: 10).count == 1)
        store.delete(since: now.addingTimeInterval(-25))
        check("(e) delete since", store.visits(since: .distantPast).map(\.url.host) == ["habr.com"])

        // (f) Prune and persistence.
        store.record(url: URL(string: "https://old.example")!, title: "Old", at: now.addingTimeInterval(-100 * 86400))
        store.prune(olderThan: 90)
        check("(f) prune", store.visits(since: .distantPast).map(\.url.host) == ["habr.com"])
        let reopened = HistoryStore(fileURL: file, deviceID: "mac")
        check("(f) persisted, FTS too", reopened.search("хабр", limit: 5).count == 1)
        reopened.deleteAll()
        check("(f) delete all", reopened.visits(since: .distantPast).isEmpty && reopened.search("хабр", limit: 5).isEmpty)

        exit(failed ? 1 : 0)
    }
}
