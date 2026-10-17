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
    /// Called with every saved session; in the via-Mac mode the link mirrors it to the Mac.
    @ObservationIgnored var onLocalChange: ((SessionSnapshot) -> Void)?
    /// Last snapshot time saved or applied, for last-writer-wins.
    @ObservationIgnored private(set) var lastModified = Date.distantPast
    @ObservationIgnored private var archive: [ArchivedTab] = []

    /// Stable per-install id, stamped on every snapshot this phone writes.
    static let deviceID: String = {
        let key = "deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    init(mode: BrowsingMode, environment: MobileWebEnvironment) {
        self.mode = mode
        self.environment = environment
        if let snapshot = Self.loadSnapshot(for: mode) {
            spaces = snapshot.spaces
            activeSpaceID = snapshot.activeSpaceID
            tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map {
                ($0.id, MobileTab(id: $0.id, url: $0.url, title: $0.title, customTitle: $0.customTitle, pinnedURL: $0.pinnedURL, lastActivated: $0.lastActivated))
            })
            // Tabs pinned before the pin address was kept start from where they are now.
            for id in spaces.flatMap(\.pinnedTabIDs) where tabs[id]?.pinnedURL == nil { tabs[id]?.pinnedURL = tabs[id]?.url }
            archive = snapshot.archive ?? []
            lastModified = snapshot.modifiedAt ?? .distantPast
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

    /// An empty name goes back to the page title.
    func renameTab(_ tabID: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[tabID]?.customTitle = name.isEmpty ? nil : name
        scheduleSave()
    }

    /// A tab in a folder is pinned inside that folder; any other tab goes to the space's pinned list.
    func togglePin(_ tabID: UUID) {
        if isInGroup(tabID) { return togglePinInGroup(tabID) }
        mutateActiveSpace { space in
            if space.pinnedTabIDs.contains(tabID) {
                tabs[tabID]?.pinnedURL = nil
                space.pinnedTabIDs.removeAll { $0 == tabID }
                space.looseTabIDs.append(tabID)
            } else {
                space.looseTabIDs.removeAll { $0 == tabID }
                for g in space.groups.indices { space.groups[g].tabIDs.removeAll { $0 == tabID } }
                space.pinnedTabIDs.append(tabID)
                tabs[tabID]?.pinnedURL = tabs[tabID]?.url
            }
        }
    }

    /// Pinned inside its folder: the tab stays there, on top, and remembers its page like any pinned tab.
    func togglePinInGroup(_ tabID: UUID) {
        guard let tab = tabs[tabID] else { return }
        tab.pinnedURL = tab.pinnedURL == nil ? tab.url : nil
        scheduleSave()
    }

    func isInGroup(_ tabID: UUID) -> Bool {
        activeSpace.groups.contains { $0.tabIDs.contains(tabID) }
    }

    /// The folder's tabs with the pinned ones first, each part in its own order.
    func orderedTabIDs(_ group: TabGroup) -> [UUID] {
        let pinned = group.tabIDs.filter { tabs[$0]?.pinnedURL != nil }
        return pinned + group.tabIDs.filter { tabs[$0]?.pinnedURL == nil }
    }

    /// Drag to reorder inside one list: a folder (as shown, pinned first), the pinned tabs, or "Сегодня".
    func reorder(group groupID: UUID?, pinned: Bool = false, from: IndexSet, to: Int) {
        mutateActiveSpace { space in
            if pinned {
                space.pinnedTabIDs.move(fromOffsets: from, toOffset: to)
            } else if let groupID, let g = space.groups.firstIndex(where: { $0.id == groupID }) {
                var ids = orderedTabIDs(space.groups[g])
                ids.move(fromOffsets: from, toOffset: to)
                space.groups[g].tabIDs = ids
            } else if groupID == nil {
                space.looseTabIDs.move(fromOffsets: from, toOffset: to)
            }
        }
    }

    func returnToPin(_ tabID: UUID) {
        guard let tab = tabs[tabID], let url = tab.pinnedURL else { return }
        tab.load(url)
        scheduleSave()
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
        tabs[tabID]?.pinnedURL = nil
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

    /// Puts the space at `index`, shifting the others; the order syncs to the paired device.
    func moveSpace(_ spaceID: UUID, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == spaceID }), from != index, spaces.indices.contains(index) else { return }
        spaces.insert(spaces.remove(at: from), at: index)
        scheduleSave()
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

    // MARK: - Mirror

    func currentSnapshot() -> SessionSnapshot {
        snapshot(modifiedAt: lastModified)
    }

    private func snapshot(modifiedAt: Date) -> SessionSnapshot {
        SessionSnapshot(
            spaces: spaces,
            activeSpaceID: activeSpaceID,
            tabs: tabs.values.map { .init(id: $0.id, url: $0.url, title: $0.title, customTitle: $0.customTitle, pinnedURL: $0.pinnedURL, lastActivated: $0.lastActivated) },
            archive: archive,
            modifiedAt: modifiedAt,
            deviceID: Self.deviceID
        )
    }

    /// Takes in the Mac's session. Tabs that stay keep their pages; the tab on
    /// screen keeps its own address. The phone's space and selection stay put.
    /// `force` applies it even if it is not newer (the Mac's merge answer).
    func applyMirror(_ remote: SessionSnapshot, force: Bool = false) {
        guard let remoteTime = remote.modifiedAt, force || remoteTime > lastModified else { return }
        saveTask?.cancel()
        let visible = activeSpace.selectedTabID
        let local = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var updated: [UUID: MobileTab] = [:]
        for record in remote.tabs {
            if let tab = tabs[record.id] {
                if let url = record.url, url != tab.url {
                    if tab.webView == nil {
                        tab.url = url
                        tab.title = record.title
                    } else if tab.id != visible {
                        tab.load(url)
                    }
                } else if tab.webView == nil {
                    tab.title = record.title
                }
                tab.customTitle = record.customTitle
                tab.pinnedURL = record.pinnedURL
                tab.lastActivated = max(tab.lastActivated, record.lastActivated)
                updated[record.id] = tab
            } else {
                updated[record.id] = MobileTab(id: record.id, url: record.url, title: record.title, customTitle: record.customTitle, pinnedURL: record.pinnedURL, lastActivated: record.lastActivated)
            }
        }
        for (id, tab) in tabs where updated[id] == nil { tab.sleep() }
        tabs = updated

        spaces = remote.spaces.map { space in
            var space = space
            // Split View is a Mac thing; the phone shows one page.
            if let mine = local[space.id] {
                if let selected = mine.selectedTabID, space.allTabIDs.contains(selected) { space.selectedTabID = selected }
                for g in space.groups.indices {
                    if let group = mine.groups.first(where: { $0.id == space.groups[g].id }) {
                        space.groups[g].isExpanded = group.isExpanded
                    }
                }
            }
            return space
        }
        if spaces.isEmpty {
            let first = Space(name: "Через Mac", colorHex: Palette.spaceColors[3])
            spaces = [first]
        }
        if !spaces.contains(where: { $0.id == activeSpaceID }) {
            activeSpaceID = spaces.contains { $0.id == remote.activeSpaceID } ? remote.activeSpaceID : spaces[0].id
        }
        archive = remote.archive ?? []
        lastModified = remoteTime
        writeToDisk(snapshot(modifiedAt: remoteTime))
    }

    // MARK: - Persistence

    private static func snapshotURL(for mode: BrowsingMode) -> URL {
        let dir = URL.applicationSupportDirectory.appending(path: "UniBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "session-\(mode.rawValue).json")
    }

    private static func loadSnapshot(for mode: BrowsingMode) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(for: mode)) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
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
        // Always later than the last applied session, so a change made after
        // taking the Mac's version wins even if the Mac's clock is ahead.
        let now = max(Date.now, lastModified.addingTimeInterval(0.001))
        lastModified = now
        let snapshot = snapshot(modifiedAt: now)
        writeToDisk(snapshot)
        onLocalChange?(snapshot)
    }

    private func writeToDisk(_ snapshot: SessionSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.snapshotURL(for: mode), options: .atomic)
        }
    }

    /// Erases the mode's tabs; used by "Стереть данные" in the via-Mac settings.
    func removeAllTabs() {
        saveTask?.cancel()
        for tab in tabs.values { tab.sleep() }
        tabs = [:]
        for index in spaces.indices {
            spaces[index].pinnedTabIDs = []
            spaces[index].groups = []
            spaces[index].looseTabIDs = []
            spaces[index].selectedTabID = nil
        }
        // Not mirrored: the Mac keeps its tabs and sends them back on the next connection.
        lastModified = .distantPast
        writeToDisk(snapshot(modifiedAt: lastModified))
    }
}
