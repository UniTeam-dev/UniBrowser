import Foundation
import Observation

/// Bookmarks and folders of one profile, kept in a JSON file. Every change is
/// saved at once; `onLocalChange` fires for the user's own edits (not merges),
/// which the iPhone link sends to the other device.
@MainActor
@Observable
final class BookmarkStore {
    /// Everything, tombstones included (for sync). Views use `children(of:)`.
    private(set) var all: [Bookmark]

    @ObservationIgnored let fileURL: URL?
    @ObservationIgnored var onLocalChange: (() -> Void)?

    /// `fileURL` nil keeps the bookmarks in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        let saved = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) }
        all = BookmarkMerge.pruned(saved ?? [], now: .now)
    }

    // MARK: - Reading

    /// Live items in a folder (nil = root), in order. Items whose folder is gone
    /// (deleted on the other device while they were added here) show at the root.
    func children(of parentID: UUID?) -> [Bookmark] {
        let folders = Set(all.filter { $0.isFolder && !$0.deleted }.map(\.id))
        return all.filter { item in
            guard !item.deleted else { return false }
            if let parentID { return item.parentID == parentID }
            return item.parentID.map { !folders.contains($0) } ?? true
        }
        .sorted { $0.order < $1.order }
    }

    func bookmark(for url: URL) -> Bookmark? {
        all.first { !$0.deleted && $0.url == url }
    }

    /// Bookmarks (not folders) whose title or address contains `query`.
    func search(_ query: String) -> [Bookmark] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return all.filter { item in
            guard !item.deleted, let url = item.url else { return false }
            return item.title.localizedStandardContains(query) || url.absoluteString.localizedStandardContains(query)
        }
    }

    // MARK: - Editing

    @discardableResult
    func add(url: URL, title: String, in parentID: UUID? = nil) -> Bookmark {
        insert(Bookmark(parentID: parentID, title: title, url: url, order: nextOrder(in: parentID)))
    }

    @discardableResult
    func addFolder(title: String, in parentID: UUID? = nil) -> Bookmark {
        insert(Bookmark(parentID: parentID, title: title, url: nil, order: nextOrder(in: parentID)))
    }

    func rename(_ id: UUID, to title: String) {
        edit(id) { $0.title = title }
    }

    /// Puts the item at `index` among the folder's items (counted without it).
    func move(_ id: UUID, to parentID: UUID?, at index: Int) {
        if let parentID, subtree(of: id).contains(parentID) { return }
        let siblings = children(of: parentID).filter { $0.id != id }
        let order: Double
        if siblings.isEmpty {
            order = 0
        } else if index <= 0 {
            order = siblings[0].order - 1
        } else if index >= siblings.count {
            order = siblings[siblings.count - 1].order + 1
        } else {
            order = (siblings[index - 1].order + siblings[index].order) / 2
        }
        edit(id) {
            $0.parentID = parentID
            $0.order = order
        }
    }

    /// Deletes the item; a folder takes everything inside it along.
    func delete(_ id: UUID) {
        let ids = subtree(of: id)
        let now = Date.now
        for index in all.indices where ids.contains(all[index].id) && !all[index].deleted {
            all[index].deleted = true
            all[index].modifiedAt = now
        }
        changed()
    }

    // MARK: - Sync

    /// Merges the other device's list (later `modifiedAt` wins per id).
    /// Returns whether anything here changed.
    @discardableResult
    func merge(_ remote: [Bookmark]) -> Bool {
        let result = BookmarkMerge.pruned(BookmarkMerge.merged(all, remote), now: .now)
        guard result != all else { return false }
        all = result
        save()
        return true
    }

    // MARK: - Private

    private func insert(_ item: Bookmark) -> Bookmark {
        all.append(item)
        changed()
        return item
    }

    private func edit(_ id: UUID, _ change: (inout Bookmark) -> Void) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[index])
        all[index].modifiedAt = .now
        changed()
    }

    private func nextOrder(in parentID: UUID?) -> Double {
        (children(of: parentID).last?.order ?? -1) + 1
    }

    /// The item and everything under it.
    private func subtree(of id: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [id]
        var grew = true
        while grew {
            grew = false
            for item in all where !ids.contains(item.id) {
                if let parent = item.parentID, ids.contains(parent) {
                    ids.insert(item.id)
                    grew = true
                }
            }
        }
        return ids
    }

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
