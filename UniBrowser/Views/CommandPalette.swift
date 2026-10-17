import SwiftUI

/// ⌘K: one field to find an open tab or group, run a command, or open a site.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store
    let mode: AppModel.PaletteMode

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private enum Item: Identifiable {
        case open(String)
        case tab(BrowserTab)
        case group(TabGroup)
        case command(String, shortcut: String?, action: @MainActor () -> Void)

        var id: String {
            switch self {
            case .open(let text): "open:\(text)"
            case .tab(let tab): "tab:\(tab.id)"
            case .group(let group): "group:\(group.id)"
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
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ text: String?) -> Bool { q.isEmpty || (text?.lowercased().contains(q) ?? false) }

        let tabs = store.tabsByRecency.filter {
            matches($0.title) || matches($0.url?.absoluteString) || matches(store.groupName(containing: $0.id))
        }
        let groups = q.isEmpty ? [] : store.activeSpace.groups.filter { matches($0.name) }
        var commands: [Item] = [
            .command("Новая группа", shortcut: "⌘⇧G") { store.newGroup(named: q.isEmpty ? "Новая группа" : query) },
            .command("Новое пространство", shortcut: nil) { store.newSpace(named: q.isEmpty ? "Пространство \(store.spaces.count + 1)" : query) },
        ]
        if let selected = store.activeSpace.selectedTabID {
            commands.append(.command("Закрепить или открепить вкладку", shortcut: "⌘⇧D") { store.togglePin(selected) })
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
        if !tabs.isEmpty { result.append(Section(title: "Открытые вкладки", items: tabs.prefix(8).map(Item.tab))) }
        if !groups.isEmpty { result.append(Section(title: "Группы", items: groups.map(Item.group))) }
        if !commands.isEmpty { result.append(Section(title: "Команды", items: commands)) }
        return result
    }

    private var flatItems: [Item] { sections.flatMap(\.items) }

    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 20 / 255, green: 20 / 255, blue: 28 / 255).opacity(0.32)
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(Palette.secondaryText)
                    TextField(mode == .newTab ? "Адрес или поиск в новой вкладке" : "Вкладки, группы, команды или адрес", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 20))
                        .focused($isFocused)
                        .onSubmit { activate(at: selection) }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                    Text("Esc")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#D1D1D6")))
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
                                row(item, isSelected: index == selection)
                                    .onTapGesture { activate(at: index) }
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
                    Spacer()
                    Text("Ctrl+Tab: недавние вкладки")
                }
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color(hex: "#F2F2F5"))
            }
            .frame(width: 660)
            .background(Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 32, y: 24)
            .padding(.top, 96)
        }
        .onAppear { isFocused = true }
        .onChange(of: query) { selection = 0 }
    }

    @ViewBuilder
    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            switch item {
            case .open(let text):
                Image(systemName: "globe").frame(width: 20)
                Text(BrowserStore.url(fromInput: text)?.host() != nil && !text.contains(" ") ? "Открыть \(text)" : "Искать «\(text)»")
                Spacer()
            case .tab(let tab):
                Favicon(tab: tab, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tab.displayTitle).font(.system(size: 14)).lineLimit(1)
                    Text([store.groupName(containing: tab.id), tab.url?.host()].compactMap { $0 }.joined(separator: " · "))
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
            case .command(let title, let shortcut, _):
                Image(systemName: "arrow.right.to.line").frame(width: 20)
                Text(title).font(.system(size: 14))
                Spacer()
                if let shortcut { Text(shortcut).font(.system(size: 12)).opacity(0.75) }
            }
        }
        .foregroundStyle(isSelected ? .white : Color(hex: "#1D1D1F"))
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(isSelected ? Palette.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
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
        case .tab(let tab):
            store.select(tab.id)
        case .group(let group):
            if let first = group.tabIDs.first { store.select(first) } else { store.toggleGroup(group.id) }
        case .command(_, _, let action):
            action()
        }
        close()
    }

    private func close() {
        model.paletteMode = nil
    }
}
