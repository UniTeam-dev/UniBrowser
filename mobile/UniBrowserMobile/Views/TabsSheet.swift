import SwiftUI

/// The phone's version of the macOS sidebar: spaces on top, then pinned tabs,
/// folder groups and "Сегодня".
struct TabsSheet: View {
    let store: MobileStore
    @Environment(\.dismiss) private var dismiss
    @State private var newGroupName = ""
    @State private var isNamingGroup = false

    var body: some View {
        NavigationStack {
            List {
                if store.spaces.count > 1 {
                    Picker("Пространство", selection: Binding(get: { store.activeSpaceID }, set: { store.switchToSpace($0) })) {
                        ForEach(store.spaces) { space in
                            Text(space.name).tag(space.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                let space = store.activeSpace

                if !space.pinnedTabIDs.isEmpty {
                    Section("Закреплённые") {
                        ForEach(space.pinnedTabIDs, id: \.self) { row($0) }
                    }
                }

                ForEach(space.groups) { group in
                    Section {
                        if group.isExpanded {
                            ForEach(group.tabIDs, id: \.self) { row($0) }
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
        }
    }

    @ViewBuilder
    private func row(_ tabID: UUID) -> some View {
        if let tab = store.tab(tabID) {
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
            }
            .buttonStyle(.plain)
            .listRowBackground(store.activeSpace.selectedTabID == tabID ? store.activeSpace.color.opacity(0.15) : nil)
            .swipeActions {
                Button("Закрыть", systemImage: "xmark", role: .destructive) { store.closeTab(tabID) }
            }
            .contextMenu {
                Button(
                    store.activeSpace.pinnedTabIDs.contains(tabID) ? "Открепить" : "Закрепить",
                    systemImage: "pin"
                ) { store.togglePin(tabID) }
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
