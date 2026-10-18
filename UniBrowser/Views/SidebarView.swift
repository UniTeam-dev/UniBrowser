import SwiftUI
import UniformTypeIdentifiers

/// The vertical tab panel from the approved design: the space rail beside the space's
/// folder groups and today's tabs, or in compact mode one column of tab and space icons.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store
    @State private var isRenamingSpace = false
    @State private var draftSpaceName = ""
    @FocusState private var isSpaceNameFocused: Bool

    var body: some View {
        let space = store.activeSpace
        Group {
            if model.isSidebarCompact {
                compactColumn(space)
                    .padding(EdgeInsets(top: 2, leading: 12, bottom: 10, trailing: 12))
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        SpaceRail(rename: startRenamingSpace)
                        VStack(alignment: .leading, spacing: 12) {
                            spaceHeader(space)
                            tabList(space)
                        }
                    }
                    bottomBar
                }
                .padding(EdgeInsets(top: 2, leading: 10, bottom: 10, trailing: 10))
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.text)
        .onChange(of: store.activeSpaceID) { isRenamingSpace = false }
    }

    /// Compact mode: pinned tabs, each folder's tabs, today's tabs, then spaces and the archive.
    private func compactColumn(_ space: Space) -> some View {
        VStack(spacing: 10) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(space.pinnedTabIDs, id: \.self) { id in
                        if let tab = store.tab(id) { TabRow(tab: tab, isCompact: true) }
                    }
                    if !space.pinnedTabIDs.isEmpty { compactDivider }
                    ForEach(space.groups.filter { !$0.tabIDs.isEmpty }) { group in
                        ForEach(store.orderedTabIDs(group), id: \.self) { id in
                            if let tab = store.tab(id) { TabRow(tab: tab, isCompact: true) }
                        }
                        compactDivider
                    }
                    ForEach(space.looseTabIDs, id: \.self) { id in
                        if let tab = store.tab(id) { TabRow(tab: tab, isCompact: true) }
                    }
                    Button { model.openPalette(.newTab) } label: {
                        Image(systemName: "plus").frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondaryText)
                    .help("Новая вкладка")
                    .accessibilityLabel("Новая вкладка")
                }
            }
            .scrollIndicators(.never)
            SpaceRail {
                withAnimation(.snappy) { model.isSidebarCompact = false }
                startRenamingSpace()
            }
            iconButton("archivebox", label: "Архив") { model.isArchiveVisible = true }
            DownloadsButton()
        }
    }

    private var compactDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 20, height: 1).padding(.vertical, 3)
    }

    private func tabList(_ space: Space) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !space.pinnedTabIDs.isEmpty {
                        SectionDivider(title: "Закреплённые")
                        ForEach(space.pinnedTabIDs, id: \.self) { id in
                            if let tab = store.tab(id) { TabRow(tab: tab) }
                        }
                        Spacer().frame(height: 10)
                    }
                    ForEach(space.groups) { group in
                        GroupSection(group: group)
                    }
                    SectionDivider(title: "Сегодня")
                        .padding(.top, space.groups.isEmpty ? 0 : 10)
                    ForEach(space.looseTabIDs, id: \.self) { id in
                        if let tab = store.tab(id) { TabRow(tab: tab) }
                    }
                    Button { model.openPalette(.newTab) } label: {
                        Label("Новая вкладка", systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.secondaryText)
                }
            }
            .scrollIndicators(.never)
    }

    private func startRenamingSpace() {
        draftSpaceName = store.activeSpace.name
        isRenamingSpace = true
        isSpaceNameFocused = true
    }

    private func spaceHeader(_ space: Space) -> some View {
        HStack(spacing: 8) {
            if isRenamingSpace {
                TextField("Название", text: $draftSpaceName)
                    .textFieldStyle(.plain)
                    .fontWeight(.semibold)
                    .focused($isSpaceNameFocused)
                    .onSubmit {
                        store.renameSpace(space.id, to: draftSpaceName)
                        isRenamingSpace = false
                    }
                    .onExitCommand { isRenamingSpace = false }
            } else {
                Text(space.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .onTapGesture(count: 2, perform: startRenamingSpace)
                    .help("Дважды щёлкните, чтобы переименовать")
            }
            Text("· \(space.allTabIDs.count) \(Plural.tabs(space.allTabIDs.count))")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
            Spacer()
            Button { store.newGroup(named: "Новая группа") } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.secondaryText)
                .accessibilityLabel("Новая группа")
        }
        .padding(.horizontal, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            iconButton("archivebox", label: "Архив") { model.isArchiveVisible = true }
            if !model.viaMac.connectedDeviceIDs.isEmpty {
                Image(systemName: "iphone")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.accent)
                    .help("iPhone подключён: вкладки синхронизируются")
                    .accessibilityLabel("iPhone подключён")
            }
            Spacer()
            DownloadsButton()
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1) }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.secondaryText)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Narrow vertical strip of spaces left of the tab list: each space is its picture
/// or colour, the active one is ringed; click switches, right-click edits.
struct SpaceRail: View {
    @Environment(BrowserStore.self) private var store
    let rename: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(store.spaces.enumerated()), id: \.element.id) { index, space in
                let isActive = space.id == store.activeSpaceID
                Button { store.switchToSpace(space.id) } label: {
                    SpaceIcon(space: space, size: 26)
                        .padding(3)
                        .overlay(Circle().stroke(isActive ? space.color : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(space.name)
                .accessibilityLabel("Пространство \(space.name)")
                .accessibilityAddTraits(isActive ? .isSelected : [])
                // Drag a space onto another to take its place.
                .draggable(space.id.uuidString) { SpaceIcon(space: space, size: 26) }
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                    withAnimation(.snappy) { store.moveSpace(id, to: index) }
                    return true
                }
                .contextMenu {
                    Button("Переименовать") {
                        store.switchToSpace(space.id)
                        DispatchQueue.main.async { rename() } // after the switch resets the header
                    }
                    Button("Выбрать картинку…") { pickImage(for: space.id) }
                    if space.imageData != nil {
                        Button("Убрать картинку") { store.setSpaceImage(space.id, nil) }
                    }
                    Divider()
                    Button("Переместить выше") { store.moveSpace(space.id, to: index - 1) }
                        .disabled(index == 0)
                    Button("Переместить ниже") { store.moveSpace(space.id, to: index + 1) }
                        .disabled(index == store.spaces.count - 1)
                    if !store.environment.isPrivate {
                        Divider()
                        Toggle("Отдельные входы", isOn: Binding(get: { space.separateLogins == true },
                                                               set: { store.setSeparateLogins(space.id, $0) }))
                        Text("Свои cookie и данные сайтов; пароли и история общие. Открытые страницы перезагрузятся.")
                        Divider()
                        Button("Удалить пространство…") { confirmDelete(space) }
                            .disabled(store.spaces.count < 2)
                    }
                }
            }
            Button { store.newSpace(named: "Пространство \(store.spaces.count + 1)") } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                    .padding(3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondaryText)
            .accessibilityLabel("Новое пространство")
        }
        .frame(width: 32)
    }

    private func confirmDelete(_ space: Space) {
        let alert = NSAlert()
        alert.messageText = "Удалить пространство «\(space.name)»?"
        alert.informativeText = space.separateLogins == true
            ? "Вкладки уйдут в архив. Входы на сайтах этого пространства, его cookie и данные сайтов будут удалены."
            : "Вкладки уйдут в архив."
        alert.addButton(withTitle: "Удалить").hasDestructiveAction = true
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn { store.deleteSpace(space.id) }
    }

    private func pickImage(for spaceID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Картинка для пространства"
        guard panel.runModal() == .OK, let url = panel.url, let data = Self.thumbnailData(url) else { return }
        store.setSpaceImage(spaceID, data)
    }

    /// Downscales to ≤128 px (the rail icon is 26 pt) so the session file and the iPhone channel stay light:
    /// JPEG for opaque pictures, PNG when there is transparency.
    static func thumbnailData(_ url: URL) -> Data? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        return opaque
            ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
            : rep.representation(using: .png, properties: [:])
    }
}

/// A space's picture cropped to a circle, or its colour when it has none.
struct SpaceIcon: View {
    let space: Space
    let size: CGFloat

    var body: some View {
        Group {
            if let data = space.imageData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                space.color
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

struct SectionDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Palette.secondaryText)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

enum Plural {
    /// "1 вкладка не открывалась", "5 вкладок не открывались".
    static func verbPast(_ n: Int, singular: String, plural: String) -> String {
        n % 10 == 1 && n % 100 != 11 ? singular : plural
    }

    static func tabs(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "вкладка" }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "вкладки" }
        return "вкладок"
    }
}
