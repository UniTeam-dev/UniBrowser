import Foundation
import Observation

/// Tabs, groups and spaces for one browsing mode. Mirrors the macOS
/// BrowserStore so both apps share the same Space/TabGroup model.
@MainActor
@Observable
final class MobileStore {
    let mode: BrowsingMode
    var spaces: [Space]
    var activeSpaceID: UUID
    private(set) var tabs: [UUID: MobileTab]

    @ObservationIgnored let environment: MobileWebEnvironment
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(mode: BrowsingMode, environment: MobileWebEnvironment) {
        self.mode = mode
        self.environment = environment
        if let snapshot = Self.loadSnapshot(for: mode) {
            spaces = snapshot.spaces
            activeSpaceID = snapshot.activeSpaceID
            tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map {
                ($0.id, MobileTab(id: $0.id, url: $0.url, title: $0.title, lastActivated: $0.lastActivated))
            })
        } else {
            let first: Space
            var rest: [Space] = []
            switch mode {
            case .direct:
                first = Space(name: "Работа", colorHex: Palette.spaceColors[0])
                rest = [Space(name: "Личное", colorHex: Palette.spaceColors[1])]
            case .viaMac:
                first = Space(name: "Через Mac", colorHex: Palette.spaceColors[3])
            }
            spaces = [first] + rest
            activeSpaceID = first.id
            tabs = [:]
        }
        environment.store = self
    }

    // MARK: - Lookup

    var activeSpaceIndex: Int {
        spaces.firstIndex { $0.id == activeSpaceID } ?? 0
    }

    var activeSpace: Space { spaces[activeSpaceIndex] }

    var selectedTab: MobileTab? {
        activeSpace.selectedTabID.flatMap { tabs[$0] }
    }

    func tab(_ id: UUID) -> MobileTab? { tabs[id] }

    var tabsByRecency: [MobileTab] {
        activeSpace.allTabIDs.compactMap { tabs[$0] }.sorted { $0.lastActivated > $1.lastActivated }
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(url: URL?, inGroup groupID: UUID? = nil, select: Bool = true) -> MobileTab {
        let tab = MobileTab(url: url)
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
        // Only the visible tab keeps a web view on the phone, to save memory.
        if let previous = selectedTab, previous.id != tabID { previous.sleep() }
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

    func deleteGroup(_ groupID: UUID) {
        guard let group = activeSpace.groups.first(where: { $0.id == groupID }) else { return }
        group.tabIDs.forEach(closeTab)
        mutateActiveSpace { $0.groups.removeAll { $0.id == groupID } }
    }

    // MARK: - Spaces

    func switchToSpace(_ spaceID: UUID) {
        selectedTab?.sleep()
        activeSpaceID = spaceID
        scheduleSave()
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

    // Same rules as BrowserStore.url(fromInput:) on macOS; moves to the shared
    // package once the macOS store is split from its web layer.
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

    private static func snapshotURL(for mode: BrowsingMode) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "UniBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "session-\(mode.rawValue).json")
    }

    private static func loadSnapshot(for mode: BrowsingMode) -> Snapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(for: mode)) else { return nil }
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
            try? data.write(to: Self.snapshotURL(for: mode), options: .atomic)
        }
    }

    /// Erases the mode's tabs; used by "Стереть данные" in the via-Mac settings.
    func removeAllTabs() {
        for tab in tabs.values { tab.sleep() }
        tabs = [:]
        for index in spaces.indices {
            spaces[index].pinnedTabIDs = []
            spaces[index].groups = []
            spaces[index].looseTabIDs = []
            spaces[index].selectedTabID = nil
        }
        saveNow()
    }
}
