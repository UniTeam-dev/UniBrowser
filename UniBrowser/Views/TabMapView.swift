import SwiftUI

/// ⌘⇧M: every tab of the space at a glance, one card per group plus "Сегодня".
/// Click a tab to open it, drag it onto another card to move it, Space to peek.
struct TabMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let space = store.activeSpace
        let duplicates = store.duplicateTabIDs.count
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                ForEach(store.spaces) { item in
                    Button { store.switchToSpace(item.id) } label: {
                        Text("\(item.name) · \(item.allTabIDs.count)")
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(item.id == space.id ? Palette.accent : .white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Разложить по группам") { store.groupLooseTabsByHost() }
                    .disabled(space.looseTabIDs.count < 2)
                Button("Закрыть дубли (\(duplicates))") { store.closeDuplicates() }
                    .disabled(duplicates == 0)
                Text("Esc — закрыть").foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 13))

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top), count: 3), spacing: 16) {
                    ForEach(space.groups) { group in
                        TabMapCard(title: group.name, symbol: "folder", tabIDs: group.tabIDs, groupID: group.id)
                    }
                    TabMapCard(title: "Сегодня", symbol: "sun.max", tabIDs: space.looseTabIDs, groupID: nil)
                }
            }
            .scrollIndicators(.never)
        }
        .foregroundStyle(.white)
        .padding(EdgeInsets(top: 40, leading: 28, bottom: 24, trailing: 28))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(hex: "#2B2D33"))
        .environment(\.colorScheme, .dark)
    }
}

/// One group (or "Сегодня") in the tab map; tabs dropped on it move into it.
private struct TabMapCard: View {
    @Environment(BrowserStore.self) private var store
    let title: String
    let symbol: String
    let tabIDs: [UUID]
    let groupID: UUID?
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.white.opacity(0.6))
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text("\(tabIDs.count)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(tabIDs, id: \.self) { id in
                    if let tab = store.tab(id) { TabMapTile(tab: tab) }
                }
            }
            if tabIDs.isEmpty {
                Text("Перетащите сюда вкладку").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(14)
        .background(.white.opacity(isDropTarget ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .dropDestination(for: String.self) { items, _ in
            for item in items { if let id = UUID(uuidString: item) { store.move(id, toGroup: groupID) } }
            return true
        } isTargeted: { isDropTarget = $0 }
    }
}

private struct TabMapTile: View {
    @Environment(AppModel.self) private var model
    let tab: BrowserTab

    var body: some View {
        Button { model.selectFromMap(tab.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                preview
                    .frame(height: 84)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        if model.mapSelection == tab.id {
                            RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(hex: "#4D8DF7"), lineWidth: 3)
                        }
                    }
                HStack(spacing: 6) {
                    Favicon(tab: tab, size: 14)
                    Text(tab.displayTitle).font(.system(size: 12)).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(tab.id.uuidString)
        .help(tab.url?.absoluteString ?? tab.displayTitle)
    }

    /// Awake tabs show their last snapshot; sleeping ones a dimmed letter tile.
    @ViewBuilder
    private var preview: some View {
        if !tab.isAsleep, let image = tab.thumbnail {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ZStack {
                Color(hex: "#3A3C43")
                Favicon(url: tab.url, size: 28)
            }
            .opacity(tab.isAsleep ? 0.5 : 1)
        }
    }
}
