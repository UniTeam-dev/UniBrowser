import Foundation
import Observation

/// All browser state for the window: spaces, groups, tabs, selection and recency.
@MainActor
@Observable
final class BrowserStore {
    var spaces: [Space]
    var activeSpaceID: UUID
    private(set) var tabs: [UUID: BrowserTab]

    @ObservationIgnored let environment: WebEnvironment
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(environment: WebEnvironment) {
        self.environment = environment
        if let snapshot = Self.loadSnapshot() {
            spaces = snapshot.spaces
            activeSpaceID = snapshot.activeSpaceID
            tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map {
                ($0.id, BrowserTab(id: $0.id, url: $0.url, title: $0.title, lastActivated: $0.lastActivated))
            })
        } else {
            let work = Space(name: "Работа", colorHex: Palette.spaceColors[0])
            spaces = [work, Space(name: "Личное", colorHex: Palette.spaceColors[1])]
            activeSpaceID = work.id
            tabs = [:]
        }
        environment.store = self
    }

    // MARK: - Lookup

    var activeSpaceIndex: Int {
        spaces.firstIndex { $0.id == activeSpaceID } ?? 0
    }

    var activeSpace: Space { spaces[activeSpaceIndex] }

    var selectedTab: BrowserTab? {
        activeSpace.selectedTabID.flatMap { tabs[$0] }
    }

    func tab(_ id: UUID) -> BrowserTab? { tabs[id] }

    /// Tabs of the active space, most recently used first. Drives Ctrl+Tab.
    var tabsByRecency: [BrowserTab] {
        activeSpace.allTabIDs.compactMap { tabs[$0] }.sorted { $0.lastActivated > $1.lastActivated }
    }

    func groupName(containing tabID: UUID) -> String? {
        activeSpace.groups.first { $0.tabIDs.contains(tabID) }?.name
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(url: URL?, inGroup groupID: UUID? = nil, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url)
        tabs[tab.id] = tab
        mutateActiveSpace { space in
            if let groupID, let index = space.groups.firstIndex(where: { $0.id == groupID }) {
                space.groups[index].tabIDs.append(tab.id)
            } else {
                space.looseTabIDs.append(tab.id)
            }
        }
        if select { self.select(tab.id) }
        return tab
    }

    func select(_ tabID: UUID) {
        guard let tab = tabs[tabID] else { return }
        if let spaceIndex = spaces.firstIndex(where: { $0.allTabIDs.contains(tabID) }) {
            activeSpaceID = spaces[spaceIndex].id
            spaces[spaceIndex].selectedTabID = tabID
            if let groupIndex = spaces[spaceIndex].groups.firstIndex(where: { $0.tabIDs.contains(tabID) }) {
                spaces[spaceIndex].groups[groupIndex].isExpanded = true
                spaces[spaceIndex].groups[groupIndex].isAsleep = false
            }
        }
        tab.lastActivated = .now
        scheduleSave()
    }

    func closeTab(_ tabID: UUID) {
        guard let tab = tabs[tabID] else { return }
        let wasSelected = activeSpace.selectedTabID == tabID
        tab.sleep()
        tabs[tabID] = nil
        for index in spaces.indices {
            spaces[index].pinnedTabIDs.removeAll { $0 == tabID }
            spaces[index].looseTabIDs.removeAll { $0 == tabID }
            for g in spaces[index].groups.indices {
                spaces[index].groups[g].tabIDs.removeAll { $0 == tabID }
            }
            if spaces[index].selectedTabID == tabID { spaces[index].selectedTabID = nil }
        }
        if wasSelected, let next = tabsByRecency.first {
            select(next.id)
        }
        scheduleSave()
    }

    func closeSelectedTab() {
        if let id = activeSpace.selectedTabID { closeTab(id) }
    }

    func togglePin(_ tabID: UUID) {
        mutateActiveSpace { space in
            if space.pinnedTabIDs.contains(tabID) {
                space.pinnedTabIDs.removeAll { $0 == tabID }
                space.looseTabIDs.append(tabID)
            } else {
                space.looseTabIDs.removeAll { $0 == tabID }
                for g in space.groups.indices { space.groups[g].tabIDs.removeAll { $0 == tabID } }
                space.pinnedTabIDs.append(tabID)
            }
        }
    }

    /// Opens what the user typed: a URL if it looks like one, otherwise a search.
    func open(input: String, inNewTab: Bool) {
        guard let url = Self.url(fromInput: input) else { return }
        if !inNewTab, let tab = selectedTab {
            tab.load(url)
        } else {
            newTab(url: url)
        }
    }

    // MARK: - Groups

    @discardableResult
    func newGroup(named name: String, with tabIDs: [UUID] = []) -> UUID {
        let group = TabGroup(name: name, tabIDs: tabIDs)
        mutateActiveSpace { space in
            space.looseTabIDs.removeAll { tabIDs.contains($0) }
            space.groups.append(group)
        }
        return group.id
    }

    func move(_ tabID: UUID, toGroup groupID: UUID?) {
        mutateActiveSpace { space in
            space.pinnedTabIDs.removeAll { $0 == tabID }
            space.looseTabIDs.removeAll { $0 == tabID }
            for g in space.groups.indices { space.groups[g].tabIDs.removeAll { $0 == tabID } }
            if let groupID, let g = space.groups.firstIndex(where: { $0.id == groupID }) {
                space.groups[g].tabIDs.append(tabID)
            } else {
                space.looseTabIDs.append(tabID)
            }
        }
    }

    func toggleGroup(_ groupID: UUID) {
        mutateActiveSpace { space in
            if let g = space.groups.firstIndex(where: { $0.id == groupID }) {
                space.groups[g].isExpanded.toggle()
            }
        }
    }

    /// Puts every tab in the group to sleep and collapses it.
    func sleepGroup(_ groupID: UUID) {
        mutateActiveSpace { space in
            guard let g = space.groups.firstIndex(where: { $0.id == groupID }) else { return }
            space.groups[g].isAsleep = true
            space.groups[g].isExpanded = false
            for id in space.groups[g].tabIDs where id != space.selectedTabID {
                tabs[id]?.sleep()
            }
        }
    }

    func renameGroup(_ groupID: UUID, to name: String) {
        mutateActiveSpace { space in
            if let g = space.groups.firstIndex(where: { $0.id == groupID }) { space.groups[g].name = name }
        }
    }

    func deleteGroup(_ groupID: UUID) {
        guard let group = activeSpace.groups.first(where: { $0.id == groupID }) else { return }
        group.tabIDs.forEach(closeTab)
        mutateActiveSpace { $0.groups.removeAll { $0.id == groupID } }
    }

    // MARK: - Spaces

    func switchToSpace(_ spaceID: UUID) {
        activeSpaceID = spaceID
        scheduleSave()
    }

    func switchToSpace(at index: Int) {
        guard spaces.indices.contains(index) else { return }
        switchToSpace(spaces[index].id)
    }

    func newSpace(named name: String) {
        let color = Palette.spaceColors[spaces.count % Palette.spaceColors.count]
        let space = Space(name: name, colorHex: color)
        spaces.append(space)
        switchToSpace(space.id)
    }

    // MARK: - Helpers

    private func mutateActiveSpace(_ change: (inout Space) -> Void) {
        change(&spaces[activeSpaceIndex])
        scheduleSave()
    }

    static func url(fromInput raw: String) -> URL? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if let url = URL(string: input), let scheme = url.scheme, ["http", "https", "file", "about"].contains(scheme) {
            return url
        }
        if !input.contains(" "), input.contains("."), let url = URL(string: "https://\(input)") {
            return url
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: input)]
        return components.url
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        struct TabRecord: Codable {
            var id: UUID
            var url: URL?
            var title: String
            var lastActivated: Date
        }
        var spaces: [Space]
        var activeSpaceID: UUID
        var tabs: [TabRecord]
    }

    private static var snapshotURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "UniBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "session.json")
    }

    private static func loadSnapshot() -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Debounced so a burst of changes writes the session file once.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let snapshot = Snapshot(
            spaces: spaces,
            activeSpaceID: activeSpaceID,
            tabs: tabs.values.map { .init(id: $0.id, url: $0.url, title: $0.title, lastActivated: $0.lastActivated) }
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.snapshotURL, options: .atomic)
        }
    }
}
