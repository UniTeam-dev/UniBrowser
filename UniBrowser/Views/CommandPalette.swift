import SwiftUI

/// ⌘K: one field to find an open tab or group, run a command, or open a site.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store
    let mode: AppModel.PaletteMode
    /// Private browsing: no search suggestions are fetched.
    var isPrivate = false

    @State private var query = ""
    @State private var selection = 0
    /// The search engine's suggestions for `query`.
    @State private var suggestions: [String] = []
    @FocusState private var isFocused: Bool

    private enum Item: Identifiable {
        case open(String)
        case suggestion(String)
        case tab(BrowserTab)
        case group(TabGroup)
        case archived(ArchivedTab)
        case bookmark(Bookmark)
        case visit(Visit)
        case sshHost(SSHHost)
        case command(String, shortcut: String?, action: @MainActor () -> Void)

        var id: String {
            switch self {
            case .open(let text): "open:\(text)"
            case .suggestion(let text): "suggestion:\(text)"
            case .tab(let tab): "tab:\(tab.id)"
            case .group(let group): "group:\(group.id)"
            case .archived(let item): "archived:\(item.id)"
            case .bookmark(let item): "bookmark:\(item.id)"
            case .visit(let visit): "visit:\(visit.id)"
            case .sshHost(let host): "ssh:\(host.id)"
            case .command(let title, _, _): "cmd:\(title)"
            }
        }
    }

    private struct Section: Identifiable {
        let title: String
        let items: [Item]
        var id: String { title }
    }

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(_ text: String?) -> Bool { q.isEmpty || (text?.lowercased().contains(q) ?? false) }
        let sshHosts = model.sshHosts.live.filter { matches("SSH: \($0.displayName)") || matches($0.address) }
        // «Новая SSH-вкладка…»: the hosts and nothing else.
        if mode == .ssh { return sshHosts.isEmpty ? [] : [Section(title: "SSH", items: sshHosts.map(Item.sshHost))] }

        let tabs = store.tabsByRecency.filter {
            matches($0.title) || matches($0.url?.absoluteString) || matches(store.groupName(containing: $0.id))
        }
        let groups = q.isEmpty ? [] : store.activeSpace.groups.filter { matches($0.name) }
        let archived = q.isEmpty ? [] : store.archive.filter { matches($0.title) || matches($0.url?.absoluteString) }
        var commands: [Item] = [
            .command("Карта вкладок", shortcut: "⌘⇧M") { model.openTabMap() },
            .command("Вечерняя уборка", shortcut: nil) { model.startCleanup() },
            .command("Расширения", shortcut: "⌘⇧E") { model.isExtensionsVisible = true },
            .command("Пароли UniBrowser", shortcut: "⌘⇧P") { model.isPasswordsVisible = true },
            .command("Новая группа", shortcut: "⌘⇧G") { store.newGroup(named: q.isEmpty ? "Новая группа" : query) },
            .command("Новое пространство", shortcut: nil) { store.newSpace(named: q.isEmpty ? "Пространство \(store.spaces.count + 1)" : query) },
        ]
        if let selected = store.activeSpace.selectedTabID {
            commands.append(.command("Закрепить или открепить вкладку", shortcut: "⌘⇧D") { store.togglePin(selected) })
            commands.append(.command("Убрать вкладку в архив", shortcut: nil) { store.archiveTab(selected) })
            if store.activeSpace.split != nil {
                commands.append(.command("Выйти из Split View", shortcut: nil) { store.endSplit() })
            }
            for group in store.activeSpace.groups {
                commands.append(.command("Переместить вкладку в группу «\(group.name)»", shortcut: nil) {
                    store.move(selected, toGroup: group.id)
                })
            }
        }
        for space in store.spaces where space.id != store.activeSpaceID {
            commands.append(.command("Перейти в пространство «\(space.name)»", shortcut: nil) { store.switchToSpace(space.id) })
        }
        commands = commands.filter {
            if case .command(let title, _, _) = $0 { return !q.isEmpty && title.lowercased().contains(q) }
            return false
        }

        var result: [Section] = []
        if !q.isEmpty { result.append(Section(title: "Открыть", items: [.open(query)])) }
        // Above the search suggestions, so typing a host's name finds it.
        if !q.isEmpty, !sshHosts.isEmpty { result.append(Section(title: "SSH", items: sshHosts.prefix(5).map(Item.sshHost))) }
        if !q.isEmpty, !suggestions.isEmpty {
            result.append(Section(title: "Поиск в \(SearchEngine.current.title)", items: suggestions.map(Item.suggestion)))
        }
        if let storeID = CRX.storeID(from: query) {
            result.append(Section(title: "Расширения", items: [
                .command("Установить расширение \(storeID) из Chrome Web Store", shortcut: nil) {
                    let manager = store.environment.extensions
                    Task { await manager.installFromStore(storeID) }
                    model.isExtensionsVisible = true
                },
            ]))
        }
        if !tabs.isEmpty { result.append(Section(title: "Вкладки", items: tabs.prefix(q.isEmpty ? 8 : 5).map(Item.tab))) }
        if !q.isEmpty {
            let bookmarks = model.bookmarks.search(query).prefix(5).map(Item.bookmark)
            if !bookmarks.isEmpty { result.append(Section(title: "Закладки", items: bookmarks)) }
            let visits = model.history.search(query, limit: 5).map(Item.visit)
            if !visits.isEmpty { result.append(Section(title: "История", items: visits)) }
        }
        if !groups.isEmpty { result.append(Section(title: "Группы", items: groups.map(Item.group))) }
        if !archived.isEmpty { result.append(Section(title: "Из архива", items: archived.prefix(5).map(Item.archived))) }
        if !commands.isEmpty { result.append(Section(title: "Команды", items: commands)) }
        return result
    }

    private var flatItems: [Item] { sections.flatMap(\.items) }

    private var placeholder: String {
        switch mode {
        case .newTab: "Адрес или поиск в новой вкладке"
        case .ssh: "SSH-сервер"
        case .search, .address: "Вкладки, группы, команды или адрес"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 20 / 255, green: 20 / 255, blue: 28 / 255).opacity(0.32)
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(Palette.secondaryText)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20))
                        .focused($isFocused)
                        .onSubmit { activate(at: selection) }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onKeyPress(keys: [.return]) { press in
                            if press.modifiers.contains(.option) {
                                peek(at: selection)
                                return .handled
                            }
                            if press.modifiers.contains(.command) {
                                split(at: selection)
                                return .handled
                            }
                            return .ignored
                        }
                    Text("Esc")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.title.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.4)
                                .foregroundStyle(Palette.secondaryText)
                                .padding(EdgeInsets(top: 10, leading: 10, bottom: 6, trailing: 10))
                            ForEach(section.items) { item in
                                let index = flatItems.firstIndex { $0.id == item.id } ?? 0
                                Button { activate(at: index) } label: {
                                    row(item, isSelected: index == selection)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    Text("↑↓ выбрать")
                    Text("↵ открыть")
                    Text("⌥↵ поверх")
                    Text("⌘↵ Split View")
                    Spacer()
                    Text("Ctrl+Tab: недавние вкладки")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Palette.surfaceAlt)
            }
            .frame(width: 660)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 32, y: 24)
            .padding(.top, 96)
        }
        .onAppear {
            if mode == .address, let url = store.selectedTab?.url, url.sshHostID == nil { query = url.absoluteString }
            // Next turn of the run loop: a click on a sidebar button would otherwise keep the focus.
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: query) { selection = 0 }
        .task(id: query) { if mode != .ssh { suggestions = await SearchSuggestions.fetch(query, isPrivate: isPrivate) } }
    }

    @ViewBuilder
    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            switch item {
            case .open(let text):
                Image(systemName: "globe").frame(width: 20)
                Text(BrowserStore.url(fromInput: text)?.host() != nil && !text.contains(" ") ? "Открыть \(text)" : "Искать «\(text)»")
                Spacer()
            case .suggestion(let text):
                Image(systemName: "magnifyingglass").frame(width: 20)
                Text(text).font(.system(size: 14)).lineLimit(1)
                Spacer()
            case .tab(let tab):
                Favicon(tab: tab, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle).font(.system(size: 14)).lineLimit(1)
                    Text([store.groupName(containing: tab.id), tab.isSSH ? "SSH" : tab.url?.host()].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .opacity(0.75)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected { Text("Перейти ↵").font(.system(size: 12)) }
            case .group(let group):
                Image(systemName: "folder").frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.name).font(.system(size: 14))
                    Text("\(group.tabIDs.count) \(Plural.tabs(group.tabIDs.count))").font(.system(size: 12)).opacity(0.75)
                }
                Spacer()
            case .archived(let item):
                Image(systemName: "archivebox").frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 14)).lineLimit(1)
                    Text(item.url?.host() ?? "").font(.system(size: 12)).opacity(0.75).lineLimit(1)
                }
                Spacer()
                Text(isSelected ? "Вернуть ↵" : "Вернуть").font(.system(size: 12)).opacity(isSelected ? 1 : 0.75)
            case .bookmark(let item):
                Favicon(url: item.url, size: 20)
                pageText(item.title, item.url)
                Spacer()
                Image(systemName: "star.fill").font(.system(size: 11)).opacity(0.75)
            case .visit(let visit):
                Favicon(url: visit.url, size: 20)
                pageText(visit.title, visit.url)
                Spacer()
                Image(systemName: "clock").font(.system(size: 11)).opacity(0.75)
            case .sshHost(let host):
                Image(systemName: "terminal").frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SSH: \(host.displayName)").font(.system(size: 14)).lineLimit(1)
                    Text("\(host.username)@\(host.address)").font(.system(size: 12)).opacity(0.75).lineLimit(1)
                }
                Spacer()
                if isSelected { Text("Открыть ↵").font(.system(size: 12)) }
            case .command(let title, let shortcut, _):
                Image(systemName: "arrow.right.to.line").frame(width: 20)
                Text(title).font(.system(size: 14))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 12)).opacity(0.75) }
            }
        }
        .foregroundStyle(isSelected ? .white : Palette.text)
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(isSelected ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    private func pageText(_ title: String, _ url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.isEmpty ? url?.absoluteString ?? "" : title).font(.system(size: 14)).lineLimit(1)
            Text(url?.host() ?? "").font(.system(size: 12)).opacity(0.75).lineLimit(1)
        }
    }

    /// The page behind a bookmark or history row.
    private func url(of item: Item) -> URL? {
        switch item {
        case .bookmark(let bookmark): bookmark.url
        case .visit(let visit): visit.url
        default: nil
        }
    }

    private func move(_ step: Int) {
        let count = flatItems.count
        guard count > 0 else { return }
        selection = (selection + step + count) % count
    }

    private func activate(at index: Int) {
        let items = flatItems
        guard items.indices.contains(index) else { return }
        switch items[index] {
        case .open(let text):
            store.open(input: text, inNewTab: mode == .newTab || store.selectedTab == nil)
        case .suggestion(let text):
            let url = SearchEngine.current.searchURL(for: text)
            if mode != .newTab, let tab = store.selectedTab, !tab.isSSH { tab.load(url) } else { store.newTab(url: url) }
        case .tab(let tab):
            store.select(tab.id)
        case .group(let group):
            if let first = group.tabIDs.first { store.select(first) } else { store.toggleGroup(group.id) }
        case .archived(let item):
            store.restore(item.id)
        case .bookmark, .visit:
            if let url = url(of: items[index]) { store.openFromLibrary(url, newTab: mode == .newTab) }
        case .sshHost(let host):
            store.openSSH(host.id)
        case .command(_, _, let action):
            action()
        }
        close()
    }

    /// ⌥↵: show the selected tab, archived page or typed address in Peek.
    private func peek(at index: Int) {
        let items = flatItems
        guard items.indices.contains(index) else { return }
        switch items[index] {
        case .open(let text):
            if let url = BrowserStore.url(fromInput: text) { model.openPeek(url) }
        case .suggestion(let text):
            model.openPeek(SearchEngine.current.searchURL(for: text))
        case .tab(let tab):
            if let url = tab.url { model.openPeek(url, sourceTabID: tab.id) }
        case .archived(let item):
            if let url = item.url { model.openPeek(url) }
        case .bookmark, .visit:
            if let url = url(of: items[index]) { model.openPeek(url) }
        case .group, .command, .sshHost:
            return
        }
        close()
    }

    /// ⌘↵: show the selected tab or typed address next to the current tab.
    private func split(at index: Int) {
        let items = flatItems
        guard items.indices.contains(index) else { return }
        switch items[index] {
        case .open(let text):
            if let url = BrowserStore.url(fromInput: text) { store.openSplit(with: store.newTab(url: url, select: false).id) }
        case .suggestion(let text):
            store.openSplit(with: store.newTab(url: SearchEngine.current.searchURL(for: text), select: false).id)
        case .tab(let tab):
            store.openSplit(with: tab.id)
        case .archived(let item):
            store.openSplit(with: store.newTab(url: item.url, select: false).id)
            store.deleteArchived(item.id)
        case .bookmark, .visit:
            if let url = url(of: items[index]) { store.openSplit(with: store.newTab(url: url, select: false).id) }
        case .sshHost(let host):
            store.openSplit(with: store.newTab(url: .ssh(host.id), select: false).id)
        case .group, .command:
            return
        }
        close()
    }

    private func close() {
        model.paletteMode = nil
    }
}
