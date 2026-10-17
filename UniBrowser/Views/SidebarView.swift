import SwiftUI
import UniformTypeIdentifiers

/// The vertical tab panel from the approved design: toolbar, address button,
/// pinned tiles, the space rail beside the space's folder groups and today's tabs.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store
    @State private var isRenamingSpace = false
    @State private var draftSpaceName = ""
    @FocusState private var isSpaceNameFocused: Bool

    var body: some View {
        let space = store.activeSpace
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            addressButton
            ExtensionBar(manager: store.environment.extensions)
            if !space.pinnedTabIDs.isEmpty {
                PinnedGrid(tabIDs: space.pinnedTabIDs)
            }
            HStack(alignment: .top, spacing: 8) {
                SpaceRail(rename: startRenamingSpace)
                VStack(alignment: .leading, spacing: 12) {
                    spaceHeader(space)
                    tabList(space)
                }
            }
            bottomBar
        }
        .font(.system(size: 13))
        .foregroundStyle(Color(hex: "#1D1D1F"))
        .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
        .onChange(of: store.activeSpaceID) { isRenamingSpace = false }
    }

    private func tabList(_ space: Space) -> some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
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

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 64) // room for the window's traffic lights
            Spacer()
            iconButton("sidebar.left", label: "Скрыть панель") {
                withAnimation(.snappy) { model.isSidebarVisible = false }
            }
            iconButton("chevron.left", label: "Назад", enabled: store.selectedTab?.canGoBack == true) {
                store.selectedTab?.webView?.goBack()
            }
            iconButton("chevron.right", label: "Вперёд", enabled: store.selectedTab?.canGoForward == true) {
                store.selectedTab?.webView?.goForward()
            }
        }
        .frame(height: 22)
    }

    private var addressButton: some View {
        Button { model.openPalette(.search) } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondaryText)
                Text(store.selectedTab?.url?.host() ?? "Поиск или адрес")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("⌘K")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondaryText)
                    .padding(.horizontal, 5)
                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            iconButton("arrow.down.to.line", label: "Загрузки") {}
        }
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.08)).frame(height: 1) }
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Palette.secondaryText : Color(hex: "#A1A1A6"))
        .disabled(!enabled)
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
            ForEach(store.spaces) { space in
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
                .contextMenu {
                    Button("Переименовать") {
                        store.switchToSpace(space.id)
                        DispatchQueue.main.async { rename() } // after the switch resets the header
                    }
                    Button("Выбрать картинку…") { pickImage(for: space.id) }
                    if space.imageData != nil {
                        Button("Убрать картинку") { store.setSpaceImage(space.id, nil) }
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
            Rectangle().fill(.black.opacity(0.1)).frame(height: 1)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

/// Pinned tabs as a 4-column grid of tiles.
struct PinnedGrid: View {
    @Environment(BrowserStore.self) private var store
    let tabIDs: [UUID]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(tabIDs, id: \.self) { id in
                if let tab = store.tab(id) {
                    Button { store.select(id) } label: {
                        Favicon(tab: tab, size: 20)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                store.activeSpace.selectedTabID == id ? Color.white : Color.white.opacity(0.75),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(tab.displayTitle)
                    .contextMenu {
                        Button("Открепить") { store.togglePin(id) }
                        Button("Закрыть") { store.closeTab(id) }
                    }
                }
            }
        }
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
