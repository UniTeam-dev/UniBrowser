import Foundation
import Observation

/// All browser state for the window: spaces, groups, tabs, selection and recency.
@MainActor
@Observable
final class BrowserStore {
    var spaces: [Space]
    var activeSpaceID: UUID
    private(set) var tabs: [UUID: BrowserTab]
    /// Newest first.
    private(set) var archive: [ArchivedTab]

    @ObservationIgnored let environment: WebEnvironment
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Called with every saved session; the iPhone link mirrors it to the phone.
    @ObservationIgnored var onLocalChange: ((SessionSnapshot) -> Void)?
    /// Last snapshot time applied or saved, for last-writer-wins.
    @ObservationIgnored private(set) var lastModified = Date.distantPast

    /// Stable per-install id, stamped on every snapshot this Mac writes.
    static let deviceID: String = {
        let key = "deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    init(environment: WebEnvironment) {
        self.environment = environment
        if let snapshot = Self.loadSnapshot() {
            spaces = snapshot.spaces
            activeSpaceID = snapshot.activeSpaceID
            archive = snapshot.archive ?? []
            tabs = Dictionary(uniqueKeysWithValues: snapshot.tabs.map {
                ($0.id, BrowserTab(id: $0.id, url: $0.url, title: $0.title, customTitle: $0.customTitle, pinnedURL: $0.pinnedURL, lastActivated: $0.lastActivated))
            })
            // Tabs pinned before the pin address was kept start from where they are now.
            for id in spaces.flatMap(\.pinnedTabIDs) where tabs[id]?.pinnedURL == nil { tabs[id]?.pinnedURL = tabs[id]?.url }
        } else {
            let work = Space(name: "Работа", colorHex: Palette.spaceColors[0])
            spaces = [work, Space(name: "Личное", colorHex: Palette.spaceColors[1])]
            activeSpaceID = work.id
            tabs = [:]
            archive = []
        }
        lastModified = (Self.loadSnapshot()?.modifiedAt) ?? .distantPast
        environment.store = self
        environment.extensions.store = self
        Task { await environment.extensions.loadAll() }
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
        environment.extensions.tabOpened(tab)
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
        let previous = activeSpace.selectedTabID.flatMap { tabs[$0] }
        if let previous, previous.id != tabID {
            previous.captureThumbnail()
        }
        if let spaceIndex = spaces.firstIndex(where: { $0.allTabIDs.contains(tabID) }) {
            activeSpaceID = spaces[spaceIndex].id
            spaces[spaceIndex].selectedTabID = tabID
            if let groupIndex = spaces[spaceIndex].groups.firstIndex(where: { $0.tabIDs.contains(tabID) }) {
                spaces[spaceIndex].groups[groupIndex].isExpanded = true
                spaces[spaceIndex].groups[groupIndex].isAsleep = false
            }
        }
        tab.lastActivated = .now
        if previous?.id != tabID { environment.extensions.tabActivated(tab, previous: previous) }
        scheduleSave()
    }

    func closeTab(_ tabID: UUID) {
        guard let tab = tabs[tabID] else { return }
        let wasSelected = activeSpace.selectedTabID == tabID
        environment.extensions.tabClosed(tabID)
        tab.sleep()
        tabs[tabID] = nil
        for index in spaces.indices {
            spaces[index].pinnedTabIDs.removeAll { $0 == tabID }
            spaces[index].looseTabIDs.removeAll { $0 == tabID }
            for g in spaces[index].groups.indices {
                spaces[index].groups[g].tabIDs.removeAll { $0 == tabID }
            }
            if spaces[index].selectedTabID == tabID { spaces[index].selectedTabID = nil }
            if spaces[index].split?.contains(tabID) == true { spaces[index].split = nil }
        }
        if wasSelected, let next = tabsByRecency.first {
            select(next.id)
        }
        scheduleSave()
    }

    func closeSelectedTab() {
        if let id = activeSpace.selectedTabID { closeTab(id) }
    }

    /// An empty name goes back to the page title.
    func renameTab(_ tabID: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[tabID]?.customTitle = name.isEmpty ? nil : name
        scheduleSave()
    }

    func togglePin(_ tabID: UUID) {
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

    // MARK: - Split View

    /// Shows `tabID` on the right of the selected tab (or of the most recent other tab).
    func openSplit(with tabID: UUID) {
        let current = activeSpace.selectedTabID.flatMap { $0 == tabID ? nil : $0 }
        guard let partner = current ?? tabsByRecency.first(where: { $0.id != tabID })?.id else { return }
        mutateActiveSpace { $0.split = SplitPair(left: partner, right: tabID) }
        select(tabID)
    }

    func swapSplit() {
        mutateActiveSpace { space in
            guard let split = space.split else { return }
            space.split = SplitPair(left: split.right, right: split.left, fraction: 1 - split.fraction)
        }
    }

    /// Leaves the left pane's tab selected.
    func endSplit() {
        guard let split = activeSpace.split else { return }
        mutateActiveSpace { $0.split = nil }
        select(split.left)
    }

    /// Called on every drag step, so it does not save; the drag's end calls `scheduleSave()`.
    func setSplitFraction(_ fraction: Double) {
        spaces[activeSpaceIndex].split?.fraction = min(max(fraction, 0.2), 0.8)
    }

    // MARK: - Archive

    /// Closes the tab but keeps its address in the archive.
    func archiveTab(_ tabID: UUID) {
        guard let tab = tabs[tabID] else { return }
        archive.insert(ArchivedTab(url: tab.url, title: tab.displayTitle, archivedAt: .now), at: 0)
        closeTab(tabID)
    }

    func restore(_ archivedID: UUID) {
        guard let index = archive.firstIndex(where: { $0.id == archivedID }) else { return }
        let item = archive.remove(at: index)
        let tab = newTab(url: item.url)
        tab.title = item.title
    }

    func deleteArchived(_ archivedID: UUID) {
        archive.removeAll { $0.id == archivedID }
        scheduleSave()
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

    // MARK: - Tab map

    /// Groups first, then "Сегодня": the order the tab map shows and arrow keys follow.
    var mapOrder: [UUID] {
        activeSpace.groups.flatMap(\.tabIDs) + activeSpace.looseTabIDs
    }

    /// Tabs in the active space whose URL another, more recently used tab already has.
    var duplicateTabIDs: [UUID] {
        let byURL = Dictionary(grouping: activeSpace.allTabIDs.compactMap { tabs[$0] }) { $0.url?.absoluteString ?? "" }
        return byURL.filter { !$0.key.isEmpty && $0.value.count > 1 }.values.flatMap { sameURL in
            sameURL.sorted { $0.lastActivated > $1.lastActivated }.dropFirst().map(\.id)
        }
    }

    func closeDuplicates() {
        duplicateTabIDs.forEach(closeTab)
    }

    /// Moves loose tabs that share a site into a group named after it; a site with one tab stays loose.
    func groupLooseTabsByHost() {
        let byHost = Dictionary(grouping: activeSpace.looseTabIDs) { id in
            tabs[id]?.url?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        }
        for (host, ids) in byHost where !host.isEmpty && ids.count > 1 {
            if let existing = activeSpace.groups.first(where: { $0.name == host }) {
                ids.forEach { move($0, toGroup: existing.id) }
            } else {
                newGroup(named: host, with: ids)
            }
        }
    }

    // MARK: - Evening cleanup

    static let staleInterval: TimeInterval = 12 * 60 * 60

    /// Loose tabs, in every space, not opened for 12+ hours. Pinned tabs, tabs in groups
    /// and the tab on screen are never offered.
    func staleLooseTabIDs(now: Date = .now) -> [UUID] {
        spaces.flatMap { space in space.looseTabIDs.filter { $0 != space.selectedTabID } }.filter { id in
            tabs[id].map { now.timeIntervalSince($0.lastActivated) >= Self.staleInterval } ?? false
        }
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

    /// Puts the space at `index`, shifting the others; the order syncs to the paired device.
    func moveSpace(_ spaceID: UUID, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == spaceID }), from != index, spaces.indices.contains(index) else { return }
        spaces.insert(spaces.remove(at: from), at: index)
        scheduleSave()
    }

    func renameSpace(_ spaceID: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[i].name = name
        scheduleSave()
    }

    func setSpaceImage(_ spaceID: UUID, _ data: Data?) {
        guard let i = spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        spaces[i].imageData = data
        scheduleSave()
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

    // MARK: - Sync

    private func snapshot(modifiedAt: Date = .now) -> SessionSnapshot {
        SessionSnapshot(
            spaces: spaces,
            activeSpaceID: activeSpaceID,
            tabs: tabs.values.map { .init(id: $0.id, url: $0.url, title: $0.title, customTitle: $0.customTitle, pinnedURL: $0.pinnedURL, lastActivated: $0.lastActivated) },
            archive: archive,
            modifiedAt: modifiedAt,
            deviceID: Self.deviceID
        )
    }

    /// The session as last saved or applied, stamped with that time.
    func currentSnapshot() -> SessionSnapshot {
        snapshot(modifiedAt: lastModified)
    }

    /// Takes in a newer session from the paired iPhone. Tabs that stay keep their
    /// live pages; a background tab follows a new address, the tab on screen keeps
    /// its own. This window's space, selected tabs and split stay as they are.
    func applyMirror(_ remote: SessionSnapshot) {
        guard let remoteTime = remote.modifiedAt, remoteTime > lastModified else { return }
        saveTask?.cancel()
        let visible = Set([activeSpace.selectedTabID, activeSpace.split?.left, activeSpace.split?.right].compactMap { $0 })
        let local = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var updated: [UUID: BrowserTab] = [:]
        for record in remote.tabs {
            if let tab = tabs[record.id] {
                if let url = record.url, url != tab.url {
                    if tab.isAsleep {
                        tab.url = url
                        tab.title = record.title
                    } else if !visible.contains(tab.id) {
                        tab.load(url)
                    }
                } else if tab.isAsleep {
                    tab.title = record.title
                }
                tab.customTitle = record.customTitle
                tab.pinnedURL = record.pinnedURL
                tab.lastActivated = max(tab.lastActivated, record.lastActivated)
                updated[record.id] = tab
            } else {
                let tab = BrowserTab(id: record.id, url: record.url, title: record.title, customTitle: record.customTitle, pinnedURL: record.pinnedURL, lastActivated: record.lastActivated)
                updated[record.id] = tab
                environment.extensions.tabOpened(tab)
            }
        }
        for (id, tab) in tabs where updated[id] == nil {
            environment.extensions.tabClosed(id)
            tab.sleep()
        }
        tabs = updated

        spaces = remote.spaces.map { space in
            var space = space
            if let mine = local[space.id] {
                // An older peer drops fields it doesn't know: absent never clears what is here.
                if space.imageData == nil { space.imageData = mine.imageData }
                if space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { space.name = mine.name }
                if let selected = mine.selectedTabID, space.allTabIDs.contains(selected) { space.selectedTabID = selected }
                if let split = mine.split, space.allTabIDs.contains(split.left), space.allTabIDs.contains(split.right) {
                    space.split = split
                } else if let split = space.split, !(space.allTabIDs.contains(split.left) && space.allTabIDs.contains(split.right)) {
                    space.split = nil
                }
                for g in space.groups.indices {
                    if let group = mine.groups.first(where: { $0.id == space.groups[g].id }) {
                        space.groups[g].isExpanded = group.isExpanded
                    }
                }
            } else {
                space.split = nil
            }
            return space
        }
        if !spaces.contains(where: { $0.id == activeSpaceID }) {
            activeSpaceID = spaces.first?.id ?? activeSpaceID
        }
        if spaces.isEmpty {
            let work = Space(name: "Работа", colorHex: Palette.spaceColors[0])
            spaces = [work]
            activeSpaceID = work.id
        }
        archive = remote.archive ?? []
        lastModified = remoteTime
        writeToDisk(snapshot(modifiedAt: remoteTime))
    }

    // MARK: - Persistence

    private static var snapshotURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "UniBrowser", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "session.json")
    }

    private static func loadSnapshot() -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
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
        // taking the iPhone's version wins even if the phone's clock is ahead.
        let now = max(Date.now, lastModified.addingTimeInterval(0.001))
        lastModified = now
        let snapshot = snapshot(modifiedAt: now)
        writeToDisk(snapshot)
        onLocalChange?(snapshot)
    }

    private func writeToDisk(_ snapshot: SessionSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: Self.snapshotURL, options: .atomic)
        }
    }
}
