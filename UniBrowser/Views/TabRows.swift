import SwiftUI
import UniformTypeIdentifiers

/// A folder group with its tabs. Tabs can be dragged onto the folder.
struct GroupSection: View {
    @Environment(BrowserStore.self) private var store
    let group: TabGroup
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { store.toggleGroup(group.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 12)
                        .foregroundStyle(Palette.secondaryText)
                    Image(systemName: "folder")
                        .foregroundStyle(group.isAsleep ? Color(hex: "#8E8E93") : Palette.accent)
                    if isRenaming {
                        TextField("Название", text: $draftName)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                store.renameGroup(group.id, to: draftName)
                                isRenaming = false
                            }
                    } else {
                        Text(group.name)
                            .fontWeight(group.isAsleep ? .regular : .medium)
                            .foregroundStyle(group.isAsleep ? Palette.secondaryText : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(group.isAsleep ? "спит · \(group.tabIDs.count)" : "\(group.tabIDs.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondaryText)
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background(isDropTarget ? Palette.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dropDestination(for: String.self) { items, _ in
                for item in items { if let id = UUID(uuidString: item) { store.move(id, toGroup: group.id) } }
                return true
            } isTargeted: { isDropTarget = $0 }
            .contextMenu {
                Button("Переименовать") { draftName = group.name; isRenaming = true }
                Button("Усыпить группу") { store.sleepGroup(group.id) }
                Divider()
                Button("Удалить группу и её вкладки", role: .destructive) { store.deleteGroup(group.id) }
            }

            if group.isExpanded {
                VStack(spacing: 2) {
                    ForEach(group.tabIDs, id: \.self) { id in
                        if let tab = store.tab(id) { TabRow(tab: tab) }
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}

struct TabRow: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    @State private var isHovered = false

    private var isSelected: Bool { store.activeSpace.selectedTabID == tab.id }

    var body: some View {
        Button { store.select(tab.id) } label: {
            HStack(spacing: 8) {
                Favicon(tab: tab, size: 16)
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(tab.isAsleep && !isSelected ? Color(hex: "#8E8E93") : .primary)
                if tab.isPlayingAudio {
                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(Palette.accent)
                        .accessibilityLabel("Играет звук")
                }
                if isHovered {
                    Button { store.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.secondaryText)
                        .accessibilityLabel("Закрыть вкладку")
                } else if tab.isAsleep && !isSelected {
                    Text("спит").font(.system(size: 11)).foregroundStyle(Color(hex: "#8E8E93"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.black.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .draggable(tab.id.uuidString)
        .contextMenu {
            Button("Закрепить") { store.togglePin(tab.id) }
            Menu("Переместить в группу") {
                ForEach(store.activeSpace.groups) { group in
                    Button(group.name) { store.move(tab.id, toGroup: group.id) }
                }
                Divider()
                Button("Без группы") { store.move(tab.id, toGroup: nil) }
            }
            Button("Открыть в Split View") { store.openSplit(with: tab.id) }
                .disabled(store.activeSpace.allTabIDs.count < 2)
            Button("Новая группа с этой вкладкой") { store.newGroup(named: "Новая группа", with: [tab.id]) }
            Divider()
            Button("Усыпить") { tab.sleep() }.disabled(tab.isAsleep || isSelected)
            Button("В архив") { store.archiveTab(tab.id) }
            Button("Закрыть") { store.closeTab(tab.id) }
        }
    }
}

/// A letter tile in a stable color per site, as in the design. Real favicons come later.
struct Favicon: View {
    let url: URL?
    var isDimmed = false
    let size: CGFloat

    init(url: URL?, isDimmed: Bool = false, size: CGFloat) {
        self.url = url
        self.isDimmed = isDimmed
        self.size = size
    }

    init(tab: BrowserTab, size: CGFloat) {
        self.init(url: tab.url, isDimmed: tab.isAsleep, size: size)
    }

    private static let colors = ["#24292F", "#6B4FD8", "#E8833A", "#D93F2B", "#2563C9", "#1E88C8", "#2E9E5B", "#F48024"]

    var body: some View {
        let host = url?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        let letter = host.first.map { String($0).uppercased() } ?? "•"
        let color = Self.colors[host.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.colors.count]
        Text(letter)
            .font(.system(size: size * 0.56, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(isDimmed ? Color(hex: "#C7C7CC") : Color(hex: color), in: RoundedRectangle(cornerRadius: size / 4))
    }
}
