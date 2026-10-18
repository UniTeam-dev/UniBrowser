import SwiftUI
import WebKit

/// The main screen: the page, with the address and controls at the bottom
/// where a thumb reaches them.
struct BrowserScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showTabs = false
    @State private var showViaMacSettings = false
    /// The address entry on screen: for the current tab, or a new one («+»).
    @State private var addressEntry: AddressTarget?
    @State private var notice: String?

    var body: some View {
        let store = model.store
        VStack(spacing: 0) {
            if model.mode == .viaMac {
                ViaMacBanner(relay: model.relay) { showViaMacSettings = true }
            }
            if let tab = store.selectedTab {
                PasswordBar(tab: tab, passwords: model.passwords)
            }
            ZStack(alignment: .top) {
                if let tab = store.selectedTab, tab.url != nil {
                    WebViewContainer(tab: tab, environment: store.environment)
                        .id(tab.id)
                        .ignoresSafeArea(edges: .horizontal)
                    if tab.isLoading {
                        ProgressView(value: tab.estimatedProgress)
                            .progressViewStyle(.linear)
                            .tint(store.activeSpace.color)
                    }
                } else {
                    StartPage(mode: model.mode, space: store.activeSpace) { openAddress(newTab: false) }
                }
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            BottomBar(
                store: store,
                mode: model.mode,
                canSendToMac: model.relay.pairedMac != nil,
                onAddress: { openAddress(newTab: false) },
                onNewTab: { openAddress(newTab: true) },
                onSwipeSpace: switchSpace,
                onTabs: { showTabs = true },
                onSwitchMode: { model.switchMode(to: $0) },
                onViaMacSettings: { showViaMacSettings = true },
                onSendToMac: sendToMac
            )
        }
        .sheet(isPresented: $showTabs) {
            TabsSheet(store: store, relay: model.mode == .viaMac ? model.relay : nil)
        }
        .sheet(isPresented: $showViaMacSettings) {
            ViaMacSettingsView()
                .environment(model)
        }
        .fullScreenCover(item: $addressEntry) { target in
            AddressEntry(store: store, initialText: target == .newTab ? "" : store.selectedTab?.url?.absoluteString ?? "") { input in
                store.open(input: input, inNewTab: target == .newTab || store.selectedTab == nil)
            }
        }
    }

    private func openAddress(newTab: Bool) {
        addressEntry = newTab ? .newTab : .currentTab
    }

    /// A swipe along the bottom bar: left goes to the next space, right to the previous one.
    private func switchSpace(by offset: Int) {
        let store = model.store
        let index = store.activeSpaceIndex + offset
        guard store.spaces.indices.contains(index) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) { store.switchToSpace(store.spaces[index].id) }
        show(store.spaces[index].name)
    }

    private func sendToMac(_ url: URL) {
        Task {
            let sent = await model.relay.sendToMac(url)
            show(sent ? "Открыто на Mac" : "Mac недоступен")
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if notice == text { notice = nil } }
        }
    }
}

private enum AddressTarget: Identifiable {
    case currentTab, newTab
    var id: Self { self }
}

/// Hosts the tab's live WKWebView. The tab owns the view; this only parents it.
struct WebViewContainer: UIViewRepresentable {
    let tab: MobileTab
    let environment: MobileWebEnvironment

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if tab.webView?.superview !== container { attach(to: container) }
    }

    private func attach(to container: UIView) {
        let webView = tab.wake(environment: environment)
        if webView.scrollView.refreshControl == nil {
            // Pull down to reload; the progress bar shows the load, so the spinner goes away at once.
            let refresh = UIRefreshControl()
            refresh.addAction(UIAction { [weak webView, weak refresh] _ in
                webView?.reload()
                refresh?.endRefreshing()
            }, for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

/// "Войти как …" when saved logins exist for the site, "Сохранить пароль?"
/// after the user signs in with a new one.
private struct PasswordBar: View {
    let tab: MobileTab
    let passwords: PhonePasswords

    var body: some View {
        if let pending = tab.pendingSave {
            bar {
                Image(systemName: "key.fill").foregroundStyle(.tint)
                Text("Сохранить пароль для **\(pending.username.isEmpty ? pending.host : pending.username)**?")
                    .lineLimit(2)
                Spacer()
                Button("Нет") { tab.pendingSave = nil }
                Button("Сохранить") {
                    passwords.save(pending)
                    tab.pendingSave = nil
                }
                .buttonStyle(.borderedProminent)
            }
        } else if !tab.loginOffers.isEmpty {
            bar {
                Image(systemName: "key.fill").foregroundStyle(.tint)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(tab.loginOffers) { credential in
                            Button(credential.username.isEmpty ? "Войти" : "Войти как \(credential.username)") {
                                tab.fill(credential)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                Button { tab.loginOffers = [] } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Скрыть")
            }
        }
    }

    private func bar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content() }
            .font(.footnote)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}

private struct BottomBar: View {
    let store: MobileStore
    let mode: BrowsingMode
    let canSendToMac: Bool
    let onAddress: () -> Void
    let onNewTab: () -> Void
    let onSwipeSpace: (Int) -> Void
    let onTabs: () -> Void
    let onSwitchMode: (BrowsingMode) -> Void
    let onViaMacSettings: () -> Void
    let onSendToMac: (URL) -> Void
    @AppStorage("appearance") var appearance = Appearance.system

    var body: some View {
        let tab = store.selectedTab
        VStack(spacing: 8) {
            HStack(spacing: 0) {
            Button(action: onAddress) {
                HStack(spacing: 6) {
                    if store.spaces.count > 1 || store.activeSpace.imageData != nil {
                        SpaceIcon(space: store.activeSpace, size: 18)
                    }
                    if mode == .viaMac {
                        Image(systemName: BrowsingMode.viaMac.systemImage)
                            .foregroundStyle(store.activeSpace.color)
                    }
                    Text(tab?.url.map { $0.absoluteString.replacingOccurrences(of: "^https?://(www\\.)?", with: "", options: .regularExpression) } ?? "Поиск или адрес")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(tab == nil ? .secondary : .primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.leading, tab?.url == nil ? 0 : 34) // keeps the address centred against the reload button
            }
            .buttonStyle(.plain)
            if let tab, tab.url != nil {
                Button {
                    if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.isLoading ? "Остановить" : "Обновить")
            }
            }
            .background(.thinMaterial, in: Capsule())

            HStack {
                Button { tab?.webView?.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!(tab?.canGoBack ?? false))
                Spacer()
                Button { tab?.webView?.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!(tab?.canGoForward ?? false))
                Spacer()
                Button(action: onNewTab) { Image(systemName: "plus") }
                Spacer()
                Button(action: onTabs) {
                    Image(systemName: "square.on.square")
                        .overlay(alignment: .topTrailing) {
                            Text("\(store.activeSpace.allTabIDs.count)")
                                .font(.caption2.bold())
                                .offset(x: 10, y: -8)
                        }
                }
                Spacer()
                Menu {
                    Section("Режим") {
                        ForEach(BrowsingMode.allCases) { option in
                            Button {
                                onSwitchMode(option)
                            } label: {
                                Label(option.title, systemImage: option == mode ? "checkmark" : option.systemImage)
                            }
                        }
                    }
                    if let url = tab?.url, canSendToMac {
                        Button("Открыть на Mac", systemImage: "laptopcomputer.and.arrow.down") { onSendToMac(url) }
                    }
                    if let url = tab?.url {
                        ShareLink(item: url)
                    }
                    Picker("Оформление", systemImage: "circle.lefthalf.filled", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.menu)
                    Button("Настройки «Через Mac»", systemImage: "gearshape", action: onViaMacSettings)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .font(.title3)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
        .contentShape(Rectangle())
        // Swipe along the bar to change spaces, like swiping Safari's address bar between tabs.
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { drag in
            let dx = drag.translation.width
            guard abs(dx) > 60, abs(dx) > abs(drag.translation.height) * 2 else { return }
            onSwipeSpace(dx < 0 ? 1 : -1)
        })
    }
}

private struct StartPage: View {
    let mode: BrowsingMode
    let space: Space
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            SpaceIcon(space: space, size: 72)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(space.color)
                        .padding(7)
                        .background(.regularMaterial, in: Circle())
                        .offset(x: 6, y: 6)
                }
            Text(space.name).font(.title2.bold())
            Text(mode == .viaMac
                 ? "Вкладки вашего Mac. Страницы открываются через его сеть."
                 : "Откройте сайт или найдите что-нибудь.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Поиск или адрес", action: onSearch)
                .buttonStyle(.borderedProminent)
                .tint(space.color)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Address entry like Safari's: the field sits above the keyboard, suggestions above it.
private struct AddressEntry: View {
    let store: MobileStore
    let initialText: String
    let onSubmit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            List {
                let query = text.trimmingCharacters(in: .whitespaces)
                if !query.isEmpty, let url = MobileStore.url(fromInput: query) {
                    let isSearch = url.host() == "www.google.com" && url.path() == "/search"
                    suggestion(isSearch ? "Искать «\(query)»" : url.absoluteString,
                               icon: isSearch ? "magnifyingglass" : "globe") { submit() }
                }
                let tabs = matchingTabs(query)
                if !tabs.isEmpty {
                    Section(query.isEmpty ? "Недавние вкладки" : "Открытые вкладки") {
                        ForEach(tabs) { tab in
                            suggestion(tab.title.isEmpty ? (tab.url?.host() ?? "Вкладка") : tab.title,
                                       detail: tab.url?.host(), icon: "square.on.square") {
                                store.select(tab.id)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск или адрес", text: $text)
                        .keyboardType(.webSearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(submit)
                    if !text.isEmpty {
                        Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Очистить")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
                Button("Отмена") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear {
            text = initialText
            focused = true
            // Like Safari: the current address starts selected, so typing replaces it.
            guard !initialText.isEmpty else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
            }
        }
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSubmit(text)
        dismiss()
    }

    /// Open tabs whose title or address contains the query; the most recent first.
    private func matchingTabs(_ query: String) -> [MobileTab] {
        let tabs = store.tabsByRecency.filter { $0.url != nil }
        guard !query.isEmpty else { return Array(tabs.prefix(6)) }
        return Array(tabs.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }.prefix(8))
    }

    private func suggestion(_ title: String, detail: String? = nil, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
        .foregroundStyle(.primary)
    }
}
