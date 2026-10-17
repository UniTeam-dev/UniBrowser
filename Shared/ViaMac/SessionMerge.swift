import Foundation

extension SessionSnapshot {
    /// Merges two sessions that changed apart (one side was offline).
    ///
    /// The later snapshot wins: its spaces, groups, order, titles and closed tabs
    /// are kept. Tabs, groups and spaces the other side created since `base`
    /// (the last session both agreed on) are added on top, so nothing opened
    /// offline is lost. A tab that is in `base` but missing from the later
    /// snapshot was closed there and stays closed.
    static func merged(_ first: SessionSnapshot, _ second: SessionSnapshot, base: SessionSnapshot?) -> SessionSnapshot {
        let firstTime = first.modifiedAt ?? .distantPast
        let secondTime = second.modifiedAt ?? .distantPast
        var result = firstTime >= secondTime ? first : second
        let other = firstTime >= secondTime ? second : first

        let baseTabs = Set(base?.tabs.map(\.id) ?? [])
        let baseSpaces = Set(base?.spaces.map(\.id) ?? [])
        let baseGroups = Set(base?.spaces.flatMap { $0.groups.map(\.id) } ?? [])
        let known = Set(result.tabs.map(\.id))
        let added = other.tabs.filter { !known.contains($0.id) && !baseTabs.contains($0.id) }
        let addedIDs = Set(added.map(\.id))
        func fresh(_ ids: [UUID]) -> [UUID] { ids.filter(addedIDs.contains) }

        var placed: Set<UUID> = []
        for space in other.spaces {
            placed.formUnion(fresh(space.allTabIDs))
            if let s = result.spaces.firstIndex(where: { $0.id == space.id }) {
                result.spaces[s].pinnedTabIDs += fresh(space.pinnedTabIDs)
                for group in space.groups {
                    let tabs = fresh(group.tabIDs)
                    if let g = result.spaces[s].groups.firstIndex(where: { $0.id == group.id }) {
                        result.spaces[s].groups[g].tabIDs += tabs
                    } else if !baseGroups.contains(group.id) {
                        // A group made on the other side; tabs it took from elsewhere stay where the winner has them.
                        var copy = group
                        copy.tabIDs = tabs
                        result.spaces[s].groups.append(copy)
                    } else {
                        // The winner deleted the group; its new tabs go loose.
                        result.spaces[s].looseTabIDs += tabs
                    }
                }
                result.spaces[s].looseTabIDs += fresh(space.looseTabIDs)
            } else if base != nil, !baseSpaces.contains(space.id) {
                var copy = space
                copy.pinnedTabIDs = fresh(space.pinnedTabIDs)
                copy.groups = space.groups.map { group in
                    var g = group
                    g.tabIDs = fresh(group.tabIDs)
                    return g
                }
                copy.looseTabIDs = fresh(space.looseTabIDs)
                copy.selectedTabID = copy.allTabIDs.contains(where: { $0 == space.selectedTabID }) ? space.selectedTabID : nil
                copy.split = nil
                result.spaces.append(copy)
            } else if !result.spaces.isEmpty {
                // First sync, or the winner deleted the space: new tabs land in the
                // space with the same name, else in the first one.
                let target = result.spaces.firstIndex { $0.name == space.name } ?? 0
                result.spaces[target].looseTabIDs += fresh(space.allTabIDs)
            }
        }
        result.tabs += added.filter { placed.contains($0.id) }

        var archive = result.archive ?? []
        let archived = Set(archive.map(\.id))
        archive += (other.archive ?? []).filter { !archived.contains($0.id) }
        result.archive = archive.sorted { $0.archivedAt > $1.archivedAt }

        result.modifiedAt = max(firstTime, secondTime)
        return result
    }

    /// Each space's picture by space id; spaces without one are left out.
    var spaceImages: [UUID: Data] {
        Dictionary(spaces.compactMap { space in space.imageData.map { (space.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    func withoutImages() -> SessionSnapshot {
        var copy = self
        for i in copy.spaces.indices { copy.spaces[i].imageData = nil }
        return copy
    }

    func withImages(_ images: [UUID: Data]) -> SessionSnapshot {
        var copy = self
        for i in copy.spaces.indices { copy.spaces[i].imageData = images[copy.spaces[i].id] }
        return copy
    }

    /// Same tabs, places and titles; ignores who wrote it and when.
    func hasSameContent(as other: SessionSnapshot) -> Bool {
        func key(_ snapshot: SessionSnapshot) -> Data? {
            var copy = snapshot
            copy.modifiedAt = nil
            copy.deviceID = nil
            copy.activeSpaceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            copy.tabs.sort { $0.id.uuidString < $1.id.uuidString }
            for i in copy.spaces.indices { copy.spaces[i].selectedTabID = nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try? encoder.encode(copy)
        }
        return key(self) == key(other)
    }
}
