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
