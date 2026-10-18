// Self-check for Shared/Library/BookmarkMerge.swift and BookmarkStore.swift:
//   swiftc -parse-as-library Shared/Library/BookmarkMerge.swift Shared/Library/BookmarkStore.swift scripts/bookmark_merge_check.swift -o /tmp/bookmark_merge_check && /tmp/bookmark_merge_check
import Foundation

@main
enum BookmarkMergeCheck {
    nonisolated(unsafe) static var failed = false

    static func check(_ name: String, _ ok: Bool) {
        print("\(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failed = true }
    }

    static func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @MainActor
    static func main() {
        // (a) Later modifiedAt wins per id; ids only one side has are kept.
        let shared = UUID(), onlyLocal = UUID(), onlyRemote = UUID()
        let local = [
            Bookmark(id: shared, title: "old", url: URL(string: "https://a.example"), order: 0, modifiedAt: at(100)),
            Bookmark(id: onlyLocal, title: "L", url: URL(string: "https://l.example"), order: 1, modifiedAt: at(100)),
        ]
        let remote = [
            Bookmark(id: shared, title: "new", url: URL(string: "https://a.example"), order: 0, modifiedAt: at(200)),
            Bookmark(id: onlyRemote, title: "R", url: URL(string: "https://r.example"), order: 2, modifiedAt: at(100)),
        ]
        let m = BookmarkMerge.merged(local, remote)
        check("(a) later wins, union of ids",
              m.count == 3 && m.first { $0.id == shared }?.title == "new"
                && Set(m.map(\.id)) == [shared, onlyLocal, onlyRemote])
        check("(a) older remote loses", BookmarkMerge.merged(remote, local).first { $0.id == shared }?.title == "new")

        // (b) A tombstone newer than the edit wins; an edit newer than the tombstone wins.
        var tomb = local[0]; tomb.deleted = true; tomb.modifiedAt = at(300)
        check("(b) newer tombstone deletes", BookmarkMerge.merged(remote, [tomb]).first { $0.id == shared }?.deleted == true)
        var edit = remote[0]; edit.modifiedAt = at(400)
        check("(b) newer edit beats tombstone", BookmarkMerge.merged([tomb], [edit]).first { $0.id == shared }?.deleted == false)

        // (c) Same time, different content: both sides pick the same one (no ping-pong).
        var x = local[0]; x.modifiedAt = at(500); x.title = "x"
        var y = local[0]; y.modifiedAt = at(500); y.title = "y"
        check("(c) tie is deterministic",
              BookmarkMerge.merged([x], [y]) == BookmarkMerge.merged([y], [x]).map { $0 }
                && BookmarkMerge.merged([x], [y])[0].title == BookmarkMerge.merged([y], [x])[0].title)

        // (d) Tombstones older than 30 days are dropped, newer ones stay.
        let now = at(100 * 86400)
        var oldTomb = local[1]; oldTomb.deleted = true; oldTomb.modifiedAt = now.addingTimeInterval(-31 * 86400)
        var freshTomb = local[0]; freshTomb.deleted = true; freshTomb.modifiedAt = now.addingTimeInterval(-29 * 86400)
        check("(d) prune old tombstones", BookmarkMerge.pruned([oldTomb, freshTomb, remote[1]], now: now).map(\.id) == [shared, onlyRemote])

        // Store: add, folders, order, move, delete subtree, search, merge, persistence.
        let file = FileManager.default.temporaryDirectory.appending(path: "bookmarks-check-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = BookmarkStore(fileURL: file)
        var changes = 0
        store.onLocalChange = { changes += 1 }
        let a = store.add(url: URL(string: "https://apple.com")!, title: "Apple")
        let folder = store.addFolder(title: "Работа")
        let g = store.add(url: URL(string: "https://github.com/x")!, title: "GitHub", in: folder.id)
        let h = store.add(url: URL(string: "https://habr.com")!, title: "Хабр", in: folder.id)
        check("(e) children in order", store.children(of: nil).map(\.id) == [a.id, folder.id]
              && store.children(of: folder.id).map(\.id) == [g.id, h.id])
        check("(e) bookmark(for:)", store.bookmark(for: URL(string: "https://github.com/x")!)?.id == g.id
              && store.bookmark(for: URL(string: "https://nope.example")!) == nil)
        check("(e) local changes reported", changes == 4)

        store.move(h.id, to: folder.id, at: 0)
        check("(f) move reorders", store.children(of: folder.id).map(\.id) == [h.id, g.id])
        store.move(a.id, to: folder.id, at: 1)
        check("(f) move into folder at index", store.children(of: folder.id).map(\.id) == [h.id, a.id, g.id]
              && store.children(of: nil).map(\.id) == [folder.id])
        store.move(folder.id, to: folder.id, at: 0)
        check("(f) folder can't go into itself", store.children(of: nil).map(\.id) == [folder.id])
        store.rename(a.id, to: "Яблоко")
        check("(f) rename", store.children(of: folder.id)[1].title == "Яблоко")

        check("(g) search by title and url, case-insensitive",
              Set(store.search("ХАБР").map(\.id)) == [h.id] && Set(store.search("github").map(\.id)) == [g.id])

        store.delete(folder.id)
        check("(h) folder delete tombstones the subtree",
              store.children(of: nil).isEmpty && store.all.count == 4 && store.all.allSatisfy(\.deleted)
                && store.bookmark(for: URL(string: "https://github.com/x")!) == nil && store.search("git").isEmpty)

        // Remote adds a bookmark into the folder we deleted: it shows at the root instead of vanishing.
        let orphan = Bookmark(parentID: folder.id, title: "Orphan", url: URL(string: "https://o.example"), order: 0, modifiedAt: .now.addingTimeInterval(60))
        let before = changes
        check("(i) merge reports a change", store.merge([orphan]) == true)
        check("(i) merge is not a local change", changes == before)
        check("(i) orphan shows at root", store.children(of: nil).map(\.id) == [orphan.id])
        check("(i) merging the same again changes nothing", store.merge(store.all) == false)

        let reloaded = BookmarkStore(fileURL: file)
        check("(j) persisted", Set(reloaded.all) == Set(store.all))

        exit(failed ? 1 : 0)
    }
}
