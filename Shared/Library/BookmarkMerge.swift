import Foundation

/// A bookmark or a folder (`url == nil`). Folders and bookmarks live in one
/// flat list linked by `parentID`; a deletion stays as a tombstone for 30 days
/// so it reaches the other device.
struct Bookmark: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    /// The folder it is in; nil is the root.
    var parentID: UUID?
    var title: String
    /// nil for a folder.
    var url: URL?
    /// Position among its siblings, ascending.
    var order: Double
    var modifiedAt: Date
    var deleted: Bool

    var isFolder: Bool { url == nil }

    init(id: UUID = UUID(), parentID: UUID? = nil, title: String, url: URL?, order: Double,
         modifiedAt: Date = .now, deleted: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.title = title
        self.url = url
        self.order = order
        self.modifiedAt = modifiedAt
        self.deleted = deleted
    }
}

/// Pure merge rules for bookmark sync: per id, the later `modifiedAt` wins.
enum BookmarkMerge {
    static let tombstoneLifetime: TimeInterval = 30 * 86400

    /// Whether `a` replaces `b` (same id). Equal times fall back to comparing the
    /// content, so both devices pick the same version and don't bounce it back.
    static func wins(_ a: Bookmark, over b: Bookmark) -> Bool {
        if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
        func key(_ x: Bookmark) -> [String] {
            [x.deleted ? "1" : "0", x.title, x.url?.absoluteString ?? "", String(x.order), x.parentID?.uuidString ?? ""]
        }
        return key(b).lexicographicallyPrecedes(key(a))
    }

    /// `local` with `remote` merged in: local order first, ids new to it appended.
    static func merged(_ local: [Bookmark], _ remote: [Bookmark]) -> [Bookmark] {
        var result = local
        var index = Dictionary(local.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in remote {
            if let i = index[item.id] {
                if wins(item, over: result[i]) { result[i] = item }
            } else {
                index[item.id] = result.count
                result.append(item)
            }
        }
        return result
    }

    /// Drops tombstones older than 30 days.
    static func pruned(_ items: [Bookmark], now: Date) -> [Bookmark] {
        items.filter { !$0.deleted || now.timeIntervalSince($0.modifiedAt) < tombstoneLifetime }
    }
}
