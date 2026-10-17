import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            AddressStrip()
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: model.isSidebarCompact ? 56 : 290)
                ContentArea()
                    .padding(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 8))
            }
        }
        .background(Palette.sidebar)
        .ignoresSafeArea()
        .overlay {
            if let mode = model.paletteMode {
                CommandPalette(mode: mode)
            }
        }
        .sheet(isPresented: Binding(
            get: { model.passwords.apple.state == .awaitingPIN },
            set: { if !$0 { model.passwords.apple.cancelPairing() } }
        )) {
            PairingSheet()
        }
        .sheet(isPresented: Bindable(model).isArchiveVisible) {
            ArchiveView()
        }
        .sheet(isPresented: Bindable(model).isExtensionsVisible) {
            ExtensionsView(manager: store.environment.extensions)
        }
        .sheet(isPresented: Bindable(model).isPasswordsVisible) {
            PasswordsManagerView(store: model.passwords.fallback)
        }
        .overlay {
            if model.isTabMapVisible {
                TabMapView()
            }
        }
        .overlay {
            if let session = model.cleanup {
                CleanupSheet(session: session)
            }
        }
        .overlay {
            if let page = model.peek {
                PeekView(page: page)
            }
        }
        .overlay {
            if let index = model.switcherIndex {
                TabSwitcherView(highlighted: index)
            }
        }
    }
}

/// The title-bar row across the window, the same with either sidebar width: sidebar toggle,
/// back/forward/reload, the current page's full URL and extension buttons. Drags the window outside its controls.
struct AddressStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let tab = store.selectedTab
        HStack(spacing: 6) {
            Spacer().frame(width: 64) // room for the window's traffic lights
            iconButton("sidebar.left", label: model.isSidebarCompact ? "Полная панель вкладок (⌃⌘S)" : "Компактная панель вкладок (⌃⌘S)") {
                withAnimation(.snappy) { model.isSidebarCompact.toggle() }
            }
            iconButton("chevron.left", label: "Назад", enabled: tab?.canGoBack == true) { tab?.webView?.goBack() }
            iconButton("chevron.right", label: "Вперёд", enabled: tab?.canGoForward == true) { tab?.webView?.goForward() }
            if tab?.isLoading == true {
                iconButton("xmark", label: "Остановить") { tab?.webView?.stopLoading() }
            } else {
                iconButton("arrow.clockwise", label: "Обновить", enabled: tab?.url != nil) { tab?.webView?.reload() }
            }
            addressButton(tab?.url)
            if let url = tab?.url {
                iconButton("doc.on.doc", label: "Скопировать адрес") { copy(url) }
            }
            ExtensionBar(manager: store.environment.extensions)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
    }

    private func addressButton(_ url: URL?) -> some View {
        Button { model.openPalette(.address) } label: {
            HStack(spacing: 6) {
                switch url?.scheme {
                case "https": Image(systemName: "lock.fill").foregroundStyle(Palette.secondaryText)
                case "http": Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Соединение не защищено")
                case nil: Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondaryText)
                default: EmptyView()
                }
                // The whole URL, the domain in full colour; long ones lose their middle, not the end.
                Group {
                    if let url {
                        let full = url.absoluteString
                        if let host = url.host(), let range = full.range(of: host) {
                            Text(full[..<range.lowerBound]).foregroundColor(Palette.secondaryText)
                                + Text(host)
                                + Text(full[range.upperBound...]).foregroundColor(Palette.secondaryText)
                        } else {
                            Text(full)
                        }
                    } else {
                        Text("Поиск или адрес").foregroundStyle(Palette.secondaryText)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url?.absoluteString ?? "")
        .contextMenu {
            if let url {
                Button("Скопировать адрес") { copy(url) }
            }
        }
    }

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func iconButton(_ symbol: String, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Palette.secondaryText : Color(hex: "#A1A1A6"))
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The white card holding the current page, or two cards side by side in Split View.
struct ContentArea: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let space = store.activeSpace
        if let split = space.split, let selected = space.selectedTabID, split.contains(selected),
           let left = store.tab(split.left), let right = store.tab(split.right) {
            SplitContent(split: split, left: left, right: right)
        } else {
            Group {
                if let tab = store.selectedTab {
                    TabPane(tab: tab)
                } else {
                    EmptyTabView()
                }
            }
            .browserCard()
        }
    }
}

/// One tab's page: the password bar, the web view and its loading bar.
struct TabPane: View {
    @Environment(BrowserStore.self) private var store
    let tab: BrowserTab

    var body: some View {
        VStack(spacing: 0) {
            PasswordBar(tab: tab)
            ZStack(alignment: .top) {
                WebViewContainer(tab: tab, environment: store.environment)
                if tab.isLoading {
                    ProgressView(value: tab.estimatedProgress)
                        .progressViewStyle(.linear)
                        .tint(Palette.accent)
                        .frame(height: 2)
                }
            }
        }
    }
}

/// Two tabs side by side with a draggable divider. The active pane has an accent ring;
/// the address bar, back/forward and ⌘W act on it.
struct SplitContent: View {
    @Environment(BrowserStore.self) private var store
    let split: SplitPair
    let left: BrowserTab
    let right: BrowserTab
    @State private var dragStartFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            let available = max(geometry.size.width - 12, 1)
            HStack(spacing: 0) {
                pane(left, isRight: false)
                    .frame(width: available * split.fraction)
                divider(available: available)
                pane(right, isRight: true)
            }
        }
    }

    private func pane(_ tab: BrowserTab, isRight: Bool) -> some View {
        let isActive = store.activeSpace.selectedTabID == tab.id
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Favicon(tab: tab, size: 16)
                Text(tab.displayTitle).lineLimit(1).font(.system(size: 12, weight: isActive ? .medium : .regular))
                Spacer()
                if isRight {
                    Button { store.swapSplit() } label: { Image(systemName: "arrow.left.arrow.right") }
                        .buttonStyle(.plain)
                        .help("Поменять местами")
                        .accessibilityLabel("Поменять местами")
                    Button { store.endSplit() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain)
                        .help("Убрать из Split View")
                        .accessibilityLabel("Убрать из Split View")
                }
            }
            .foregroundStyle(Palette.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .onTapGesture { store.select(tab.id) }
            Divider()
            TabPane(tab: tab)
        }
        .browserCard(isActive: isActive)
    }

    private func divider(available: Double) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(hex: "#A1A1A6"))
            .frame(width: 4, height: 44)
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartFraction ?? split.fraction
                        dragStartFraction = start
                        store.setSplitFraction(start + value.translation.width / available)
                    }
                    .onEnded { _ in
                        dragStartFraction = nil
                        store.scheduleSave()
                    }
            )
            .accessibilityLabel("Граница Split View")
    }
}

extension View {
    /// The rounded white page card; `isActive` adds the Split View accent ring.
    func browserCard(isActive: Bool = false) -> some View {
        background(Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isActive ? Palette.accent : Color.primary.opacity(0.06), lineWidth: isActive ? 2 : 1)
            )
    }
}

struct EmptyTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Text("Нет открытых вкладок")
                .font(.title2.weight(.semibold))
            Button("Открыть адрес или найти  ⌘K") { model.openPalette(.newTab) }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Hosts the selected tab's WKWebView, waking the tab if it was asleep.
struct WebViewContainer: NSViewRepresentable {
    let tab: BrowserTab
    let environment: WebEnvironment

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        let webView = tab.wake(environment: environment)
        guard let hostView = tab.hostView, hostView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)
        NSLayoutConstraint.activate([
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.window?.makeFirstResponder(webView)
    }
}
