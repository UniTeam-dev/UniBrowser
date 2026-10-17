import SwiftUI

/// The phone's version of the macOS sidebar: spaces on top, then pinned tabs,
/// folder groups and "Сегодня". In the via-Mac mode these are the Mac's own tabs.
struct TabsSheet: View {
    let store: MobileStore
    /// Set in the via-Mac mode, to show whether the mirror is live.
    var relay: MacRelay?
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""
    @State private var isNamingGroup = false
    @State private var renamingTabID: UUID?
    @State private var tabName = ""

    var body: some View {
        NavigationStack {
            List {
                if let relay {
                    Label(syncText(relay), systemImage: relay.isSyncing ? "arrow.triangle.2.circlepath" : "laptopcomputer.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                if store.spaces.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.spaces) { spaceChip($0) }
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }

                let space = store.activeSpace

                if !space.pinnedTabIDs.isEmpty {
                    Section("Закреплённые") {
                        ForEach(space.pinnedTabIDs, id: \.self) { row($0) }
                            .onMove { store.reorder(group: nil, pinned: true, from: $0, to: $1) }
                    }
                }

                ForEach(space.groups) { group in
                    Section {
                        if group.isExpanded {
                            ForEach(store.orderedTabIDs(group), id: \.self) { row($0) }
                                .onMove { store.reorder(group: group.id, from: $0, to: $1) }
                        }
                    } header: {
                        Button {
                            store.toggleGroup(group.id)
                        } label: {
                            Label(group.name, systemImage: group.isExpanded ? "folder" : "folder.fill")
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Удалить группу с вкладками", systemImage: "trash", role: .destructive) {
                                store.deleteGroup(group.id)
                            }
                        }
                    }
                }

                Section("Сегодня") {
                    ForEach(space.looseTabIDs, id: \.self) { row($0) }
                        .onMove { store.reorder(group: nil, from: $0, to: $1) }
                }
            }
            .navigationTitle(store.activeSpace.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Новая группа", systemImage: "folder.badge.plus") { isNamingGroup = true }
                    Spacer()
                    Button("Новая вкладка", systemImage: "plus") {
                        store.newTab(url: nil)
                        dismiss()
                    }
                }
            }
            .alert("Новая группа", isPresented: $isNamingGroup) {
                TextField("Название", text: $newGroupName)
                Button("Создать") {
                    let name = newGroupName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { store.newGroup(named: name) }
                    newGroupName = ""
                }
                Button("Отмена", role: .cancel) { newGroupName = "" }
            }
            .alert("Название вкладки", isPresented: Binding(get: { renamingTabID != nil }, set: { if !$0 { renamingTabID = nil } })) {
                TextField("Пусто — название страницы", text: $tabName)
                Button("Сохранить") { if let id = renamingTabID { store.renameTab(id, to: tabName) } }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func syncText(_ relay: MacRelay) -> String {
        guard let mac = relay.pairedMac else { return "Mac не подключён: вкладки только на телефоне" }
        if relay.isSyncing { return "Вкладки синхронизируются с «\(mac.name)»" }
        return "Нет связи с «\(mac.name)»: изменения уйдут на Mac при подключении"
    }

    private func spaceChip(_ space: Space) -> some View {
        let isActive = space.id == store.activeSpaceID
        return Button {
            store.switchToSpace(space.id)
        } label: {
            HStack(spacing: 6) {
                SpaceIcon(space: space, size: 22)
                Text(space.name).lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 5)
            .background(isActive ? space.color.opacity(0.22) : Color(.secondarySystemBackground), in: Capsule())
            .overlay(Capsule().strokeBorder(isActive ? space.color : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Пространство \(space.name)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            if let index = store.spaces.firstIndex(where: { $0.id == space.id }) {
                Button("Переместить влево", systemImage: "arrow.left") { store.moveSpace(space.id, to: index - 1) }
                    .disabled(index == 0)
                Button("Переместить вправо", systemImage: "arrow.right") { store.moveSpace(space.id, to: index + 1) }
                    .disabled(index == store.spaces.count - 1)
            }
        }
    }

    @ViewBuilder
    private func row(_ tabID: UUID) -> some View {
        if let tab = store.tab(tabID) {
            HStack {
                Button {
                    store.select(tabID)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.displayTitle).lineLimit(1)
                        if let host = tab.url?.host() {
                            Text(host).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                if tab.isAwayFromPin {
                    Button("📌") { store.returnToPin(tabID) }
                        .accessibilityLabel("Вернуть на закреплённую страницу")
                } else if tab.pinnedURL != nil && store.isInGroup(tabID) {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Закреплена в папке")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .listRowBackground(store.activeSpace.selectedTabID == tabID ? store.activeSpace.color.opacity(0.15) : nil)
            .swipeActions {
                Button("Закрыть", systemImage: "xmark", role: .destructive) { store.closeTab(tabID) }
            }
            .contextMenu {
                Button(tab.pinnedURL == nil ? "Закрепить" : "Открепить", systemImage: "pin") { store.togglePin(tabID) }
                if tab.isAwayFromPin {
                    Button("Вернуть на закреплённую страницу", systemImage: "pin") { store.returnToPin(tabID) }
                }
                Button("Переименовать", systemImage: "pencil") {
                    tabName = tab.customTitle ?? ""
                    renamingTabID = tabID
                }
                Menu("В группу", systemImage: "folder") {
                    ForEach(store.activeSpace.groups) { group in
                        Button(group.name) { store.move(tabID, toGroup: group.id) }
                    }
                    Button("Без группы") { store.move(tabID, toGroup: nil) }
                }
                Button("Закрыть", systemImage: "xmark", role: .destructive) { store.closeTab(tabID) }
            }
        }
    }
}
