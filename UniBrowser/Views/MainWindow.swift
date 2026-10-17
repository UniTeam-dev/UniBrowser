import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarView()
                    .frame(width: 290)
                    .transition(.move(edge: .leading))
            }
            VStack(spacing: 0) {
                if !model.isSidebarVisible {
                    showSidebarBar
                }
                ContentArea()
                    .padding(EdgeInsets(top: 8, leading: model.isSidebarVisible ? 0 : 8, bottom: 8, trailing: 8))
            }
        }
        .background(Palette.sidebar)
        .ignoresSafeArea()
        .overlay {
            if let mode = model.paletteMode {
                CommandPalette(mode: mode)
            }
        }
        #if DIRECT
        .sheet(isPresented: Binding(
            get: { model.passwords.apple.state == .awaitingPIN },
            set: { if !$0 { model.passwords.apple.cancelPairing() } }
        )) {
            PairingSheet()
        }
        #endif
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

    /// With the sidebar hidden, a strip beside the traffic lights keeps a way to bring it back.
    private var showSidebarBar: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 64) // room for the window's traffic lights
            Button { withAnimation(.snappy) { model.isSidebarVisible = true } } label: {
                Image(systemName: "sidebar.left").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.secondaryText)
            .help("Показать панель вкладок (⌃⌘S)")
            .accessibilityLabel("Показать панель вкладок")
            Spacer()
        }
        .font(.system(size: 13))
        .frame(height: 22)
        .padding(EdgeInsets(top: 12, leading: 10, bottom: 0, trailing: 10))
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
