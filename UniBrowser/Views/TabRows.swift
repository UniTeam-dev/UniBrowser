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
                    ForEach(store.orderedTabIDs(group), id: \.self) { id in
                        if let tab = store.tab(id) { TabRow(tab: tab) }
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}

/// A tab in the sidebar list, or with `isCompact` just its icon in the narrow sidebar
/// (title as a tooltip, the same menu and drag and drop).
struct TabRow: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab
    var isCompact = false
    @State private var isHovered = false
    @State private var isDropTarget = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    private var isSelected: Bool { store.activeSpace.selectedTabID == tab.id }

    var body: some View {
        Button { store.select(tab.id) } label: {
            Group {
                if isCompact {
                    Favicon(tab: tab, size: 16).frame(width: 32, height: 32)
                } else {
                    row
                }
            }
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Palette.surface)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isCompact ? tab.displayTitle : "")
        // No room for the name field in the narrow sidebar, so renaming happens in a popover.
        .popover(isPresented: isCompact ? $isRenaming : .constant(false), arrowEdge: .trailing) {
            nameField.frame(width: 220).padding(10)
        }
        .onHover { isHovered = $0 }
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            withAnimation(.snappy) { store.moveTab(id, before: tab.id) }
            return true
        } isTargeted: { isDropTarget = $0 }
        // A line above the row shows where the dragged tab will land.
        .overlay(alignment: .top) {
            if isDropTarget { Capsule().fill(Palette.accent).frame(height: 2).offset(y: -1) }
        }
        .contextMenu {
            Button(tab.pinnedURL == nil ? "Закрепить" : "Открепить") { store.togglePin(tab.id) }
            if tab.isAwayFromPin {
                Button("Вернуть на закреплённую страницу") { store.returnToPin(tab.id) }
            }
            Button("Переименовать") { draftName = tab.customTitle ?? ""; isRenaming = true }
            if tab.customTitle != nil {
                Button("Вернуть название страницы") { store.renameTab(tab.id, to: "") }
            }
            Menu("Переместить в группу") {
                ForEach(store.activeSpace.groups) { group in
                    Button(group.name) { store.move(tab.id, toGroup: group.id) }
                }
                Divider()
                Button("Без группы") { store.move(tab.id, toGroup: nil) }
            }
            if store.spaces.count > 1 {
                Menu("Переместить в пространство") {
                    ForEach(store.spaces.filter { $0.id != store.activeSpaceID }) { space in
                        Button(space.name) { store.moveTab(tab.id, toSpace: space.id) }
                    }
                }
            }
            Button("Открыть в Split View") { store.openSplit(with: tab.id) }
                .disabled(store.activeSpace.allTabIDs.count < 2)
            Button("Новая группа с этой вкладкой") { store.newGroup(named: "Новая группа", with: [tab.id]) }
            Button(tab.isMuted ? "Включить звук" : "Выключить звук") { tab.setMuted(!tab.isMuted) }
            Divider()
            Button("Усыпить") { tab.sleep() }.disabled(tab.isAsleep || isSelected)
            Button("В архив") { store.archiveTab(tab.id) }
            Button("Закрыть") { store.closeTab(tab.id) }
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Favicon(tab: tab, size: 16)
            if isRenaming {
                nameField
            } else {
                Text(tab.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(tab.isAsleep && !isSelected ? Color(hex: "#8E8E93") : .primary)
            }
            if tab.isPlayingAudio || tab.isMuted {
                Button { tab.setMuted(!tab.isMuted) } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash" : "speaker.wave.2")
                }
                .buttonStyle(.plain)
                .foregroundStyle(tab.isMuted ? Palette.secondaryText : Palette.accent)
                .help(tab.isMuted ? "Включить звук" : "Выключить звук")
                .accessibilityLabel(tab.isMuted ? "Включить звук" : "Выключить звук")
            }
            if isHovered {
                Button { store.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityLabel("Закрыть вкладку")
            } else if tab.isAsleep && !isSelected {
                Text("спит").font(.system(size: 11)).foregroundStyle(Color(hex: "#8E8E93"))
            }
            // Last, so the hover close button appears beside it instead of in its place.
            if tab.isAwayFromPin {
                Button { store.returnToPin(tab.id) } label: { Text("📌").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .help("Вернуть на закреплённую страницу")
                    .accessibilityLabel("Вернуть на закреплённую страницу")
            } else if tab.pinnedURL != nil && store.isInGroup(tab.id) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.secondaryText)
                    .accessibilityLabel("Закреплена в папке")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }

    private var nameField: some View {
        TextField(tab.title.isEmpty ? "Название" : tab.title, text: $draftName)
            .textFieldStyle(.plain)
            .onSubmit {
                store.renameTab(tab.id, to: draftName)
                isRenaming = false
            }
            .onExitCommand { isRenaming = false }
            .focused($isNameFocused)
            .onAppear { isNameFocused = true }
            .onChange(of: isNameFocused) { if !isNameFocused { isRenaming = false } }
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
            .background(isDimmed ? Palette.dimmed : Color(hex: color), in: RoundedRectangle(cornerRadius: size / 4))
    }
}
