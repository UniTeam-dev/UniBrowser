import SwiftUI
import WebKit

/// The main screen: the page, with the address and controls at the bottom
/// where a thumb reaches them.
struct BrowserScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showTabs = false
    @State private var showViaMacSettings = false
    @State private var showDownloads = false
    @State private var showSiteInfo = false
    /// The address entry on screen: for the current tab, or a new one («+»).
    @State private var addressEntry: AddressTarget?
    @State private var notice: String?
    @State private var showBookmarkEditor = false
    @State private var showSettings = false
    /// «Настройки «Через Mac»» chosen in Настройки: opened once that sheet is gone.
    @State private var viaMacAfterSettings = false
    /// «Сохранить как PDF»: the page, waiting for the Files save sheet.
    @State private var pdf: PDFFile?
    @State private var pdfName = ""
    /// The on-screen keyboard is up: over a terminal the bottom bar steps aside for the shell.
    @State private var isKeyboardUp = false

    var body: some View {
        let store = model.store
        VStack(spacing: 0) {
            if model.mode == .viaMac {
                ViaMacBanner(relay: model.relay) { showViaMacSettings = true }
            }
            if let request = store.selectedTab?.permissionRequest {
                PermissionBar(request: request)
            }
            if let tab = store.selectedTab {
                PasswordBar(tab: tab, passwords: model.passwords)
            }
            ZStack(alignment: .top) {
                if let tab = store.selectedTab, let hostID = tab.url?.sshHostID {
                    SSHTabScreen(tab: tab, hostID: hostID)
                        .id(tab.id)
                } else if let tab = store.selectedTab, tab.url != nil {
                    WebViewContainer(tab: tab, environment: store.environment)
                        .id(tab.id)
                        .ignoresSafeArea(edges: .horizontal)
                    if let article = tab.reader {
                        ReaderPage(article: article, onClose: { tab.reader = nil }) { url in
                            tab.reader = nil
                            tab.load(url)
                        }
                    }
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
            if !(isKeyboardUp && store.selectedTab?.isSSH == true) {
                BottomBar(
                    store: store,
                    mode: model.mode,
                    canSendToMac: model.relay.pairedMac != nil,
                    // A tab on a deleted server has nothing to reconnect to.
                    canReload: store.selectedTab?.url?.sshHostID.map { model.sshHosts.host($0) != nil } ?? true,
                    onAddress: { openAddress(newTab: false) },
                    onNewTab: {
                        if let url = HomePage.url { store.newTab(url: url) } else { openAddress(newTab: true) }
                    },
                    onSwipeSpace: switchSpace,
                    onTabs: { showTabs = true },
                    onSwitchMode: { model.switchMode(to: $0) },
                    onViaMacSettings: { showViaMacSettings = true },
                    onSiteInfo: { showSiteInfo = true },
                    onSendToMac: sendToMac,
                    onDownloads: { showDownloads = true },
                    onBookmark: { showBookmarkEditor = true },
                    onSettings: { showSettings = true },
                    onSavePDF: savePDF
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in isKeyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in isKeyboardUp = false }
        .sheet(isPresented: $showTabs) {
            TabsSheet(store: store, relay: model.mode == .viaMac ? model.relay : nil)
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsSheet()
        }
        .sheet(isPresented: $showSiteInfo) {
            if let webView = store.selectedTab?.webView {
                NavigationStack {
                    SiteInfoView(webView: webView, settings: store.environment.siteSettings,
                                 permissions: [.camera, .microphone],
                                 permissionsNote: "Геопозицию iOS спрашивает сама, когда сайт её запросит.")
                        .navigationTitle("О сайте")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Готово") { showSiteInfo = false } }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showBookmarkEditor) {
            if let tab = store.selectedTab, let url = tab.url {
                BookmarkEditor(bookmarks: store.bookmarks, url: url, title: tab.displayTitle)
            }
        }
        .sheet(isPresented: $showViaMacSettings) {
            ViaMacSettingsView()
                .environment(model)
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            if viaMacAfterSettings { viaMacAfterSettings = false; showViaMacSettings = true }
        }) {
            SettingsSheet { viaMacAfterSettings = true }
                .environment(model)
        }
        .fileExporter(isPresented: Binding(get: { pdf != nil }, set: { if !$0 { pdf = nil } }),
                      document: pdf, contentType: .pdf, defaultFilename: pdfName) { result in
            if case .success = result { show("PDF сохранён") }
        }
        .fullScreenCover(item: $addressEntry) { target in
            let current = target == .newTab ? nil : store.selectedTab
            AddressEntry(store: store, initialText: current?.isSSH == false ? current?.url?.absoluteString ?? "" : "",
                         isPrivate: store.environment.isPrivate, hosts: model.sshHosts.live,
                         onSSH: { store.openSSH($0) }) { url in
                // A page never replaces a terminal: it opens beside it.
                if let current, !current.isSSH { current.load(url) } else { store.newTab(url: url) }
            }
        }
    }

    private func savePDF() {
        guard let tab = model.store.selectedTab, let webView = tab.webView else { return }
        Task {
            do {
                let data = try await webView.pdf()
                pdfName = tab.displayTitle.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
                pdf = PDFFile(data: data)
            } catch {
                show("Не удалось сохранить PDF")
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
    let canReload: Bool
    let onAddress: () -> Void
    let onNewTab: () -> Void
    let onSwipeSpace: (Int) -> Void
    let onTabs: () -> Void
    let onSwitchMode: (BrowsingMode) -> Void
    let onViaMacSettings: () -> Void
    let onSiteInfo: () -> Void
    let onSendToMac: (URL) -> Void
    let onDownloads: () -> Void
    let onBookmark: () -> Void
    let onSettings: () -> Void
    let onSavePDF: () -> Void
    @AppStorage("appearance") var appearance = Appearance.system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tab = store.selectedTab
        // A terminal has no page to share, find in, zoom, bookmark, read or save.
        let page = tab?.isSSH == true ? nil : tab
        VStack(spacing: 8) {
            HStack(spacing: 0) {
            Button(action: onAddress) {
                HStack(spacing: 6) {
                    if store.spaces.count > 1 || store.activeSpace.imageData != nil {
                        SpaceIcon(space: store.activeSpace, size: 18)
                    }
                    if mode != .direct {
                        Image(systemName: mode.systemImage)
                            .foregroundStyle(store.activeSpace.color)
                    }
                    Text(tab?.isSSH == true ? "SSH: \(tab?.displayTitle ?? "")"
                         : tab?.url.map { $0.absoluteString.replacingOccurrences(of: "^https?://(www\\.)?", with: "", options: .regularExpression) } ?? "Поиск или адрес")
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
                    if tab.isSSH { tab.isNewSSHSession = false; tab.sshTerminal?.connect() } // only if not connected
                    else if tab.isLoading { tab.webView?.stopLoading() } else { tab.webView?.reload() }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canReload)
                .accessibilityLabel(tab.isSSH ? "Переподключиться" : tab.isLoading ? "Остановить" : "Обновить")
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
                // Tap: new tab; long press: recently closed tabs.
                Menu {
                    Section("Недавно закрытые") {
                        if store.recentlyClosed.isEmpty { Text("Пока ничего") }
                        ForEach(store.recentlyClosed) { item in
                            Button(item.title.isEmpty ? (item.url?.host() ?? "Вкладка") : item.title) {
                                store.reopenClosed(item.id)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                } primaryAction: {
                    onNewTab()
                }
                .accessibilityLabel("Новая вкладка")
                .accessibilityHint("Удерживайте, чтобы открыть недавно закрытые")
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
                    if let url = page?.url, canSendToMac {
                        Button("Открыть на Mac", systemImage: "laptopcomputer.and.arrow.down") { onSendToMac(url) }
                    }
                    if let url = page?.url {
                        ShareLink(item: url)
                    }
                    if let tab = page, tab.url != nil {
                        Button("Найти на странице", systemImage: "doc.text.magnifyingglass") { tab.showFind() }
                        ZoomMenuRow(store: store, tab: tab)
                    }
                    Button("Загрузки", systemImage: "arrow.down.circle", action: onDownloads)
                    if page?.webView != nil, page?.url != nil {
                        Button("О сайте", systemImage: "info.circle", action: onSiteInfo)
                    }
                    if let url = page?.url {
                        Section {
                            let isBookmarked = store.bookmarks.bookmark(for: url) != nil
                            Button(isBookmarked ? "Изменить закладку" : "Добавить в закладки",
                                   systemImage: isBookmarked ? "star.fill" : "star", action: onBookmark)
                        }
                    }
                    if let tab = page, tab.isReadable || tab.reader != nil {
                        Button(tab.reader == nil ? "Режим чтения" : "Выйти из режима чтения", systemImage: "doc.plaintext") {
                            if tab.reader != nil { tab.reader = nil; return }
                            guard let webView = tab.webView else { return }
                            Task { tab.reader = await ReaderMode.article(from: webView) }
                        }
                    }
                    if let tab = page, tab.url != nil {
                        Button("Сохранить как PDF", systemImage: "doc.richtext", action: onSavePDF)
                        Button(tab.isMuted ? "Включить звук" : "Выключить звук",
                               systemImage: tab.isMuted ? "speaker.wave.2" : "speaker.slash") { tab.setMuted(!tab.isMuted) }
                    }
                    Picker("Оформление", systemImage: "circle.lefthalf.filled", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.title) }
                    }
                    .pickerStyle(.menu)
                    Button("Настройки «Через Mac»", systemImage: "laptopcomputer.and.iphone", action: onViaMacSettings)
                    Button("Настройки", systemImage: "gearshape", action: onSettings)
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
        // Dark violet in private mode, like the Mac's private window.
        .background(mode == .private ? AnyShapeStyle(Color(hex: "#2A1B47")) : AnyShapeStyle(.bar))
        .environment(\.colorScheme, mode == .private ? .dark : colorScheme)
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
            Text(hint)
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

    private var hint: String {
        switch mode {
        case .viaMac: "Вкладки вашего Mac. Страницы открываются через его сеть."
        case .private: "История, cookie и вкладки не сохраняются и закроются, когда вы выйдете из режима."
        case .direct: "Откройте сайт или найдите что-нибудь."
        }
    }
}

/// Address entry like Safari's: the field sits above the keyboard, suggestions above it.
private struct AddressEntry: View {
    let store: MobileStore
    let initialText: String
    /// Private browsing: no search suggestions are fetched.
    var isPrivate = false
    /// Saved SSH servers, offered as «SSH: name»; picking one opens it in a new tab.
    var hosts: [SSHHost] = []
    var onSSH: (UUID) -> Void = { _ in }
    let onSubmit: (URL) -> Void
    @State private var suggestions: [String] = []
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            List {
                let query = text.trimmingCharacters(in: .whitespaces)
                if !query.isEmpty, let url = MobileStore.url(fromInput: query) {
                    let isSearch = SearchEngine.current.query(in: url) != nil
                    suggestion(isSearch ? "Искать «\(query)»" : url.absoluteString,
                               icon: isSearch ? "magnifyingglass" : "globe") { submit() }
                }
                let servers = query.isEmpty ? [] : hosts.filter {
                    "SSH: \($0.displayName)".localizedCaseInsensitiveContains(query) || $0.address.localizedCaseInsensitiveContains(query)
                }
                if !servers.isEmpty {
                    Section("SSH-серверы") {
                        ForEach(servers) { host in
                            suggestion("SSH: \(host.displayName)", detail: "\(host.username)@\(host.address)", icon: "terminal") {
                                onSSH(host.id)
                                dismiss()
                            }
                        }
                    }
                }
                if !query.isEmpty, !suggestions.isEmpty {
                    Section("Поиск в \(SearchEngine.current.title)") {
                        ForEach(suggestions, id: \.self) { text in
                            suggestion(text, icon: "magnifyingglass") {
                                onSubmit(SearchEngine.current.searchURL(for: text))
                                dismiss()
                            }
                        }
                    }
                }
                let tabs = matchingTabs(query)
                if !tabs.isEmpty {
                    Section(query.isEmpty ? "Недавние вкладки" : "Открытые вкладки") {
                        ForEach(tabs) { tab in
                            suggestion(tab.title.isEmpty ? (tab.url?.host() ?? "Вкладка") : tab.title,
                                       detail: tab.isSSH ? "SSH" : tab.url?.host(), icon: tab.isSSH ? "terminal" : "square.on.square") {
                                store.select(tab.id)
                                dismiss()
                            }
                        }
                    }
                }
                let marks = query.isEmpty ? [] : Array(store.bookmarks.search(query).prefix(4))
                if !marks.isEmpty {
                    Section("Закладки") {
                        ForEach(marks) { mark in
                            if let url = mark.url {
                                suggestion(mark.title.isEmpty ? (url.host() ?? url.absoluteString) : mark.title,
                                           detail: url.host(), icon: "book") { open(url) }
                            }
                        }
                    }
                }
                let listed = Set(tabs.compactMap(\.url) + marks.compactMap(\.url))
                let visits = query.isEmpty ? [] : (store.history?.search(query, limit: 8) ?? []).filter { !listed.contains($0.url) }.prefix(4)
                if !visits.isEmpty {
                    Section("История") {
                        ForEach(visits) { visit in
                            suggestion(visit.title.isEmpty ? visit.url.absoluteString : visit.title,
                                       detail: visit.host, icon: "clock") { open(visit.url) }
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
        .task(id: text) {
            suggestions = await SearchSuggestions.fetch(text, isPrivate: isPrivate, session: store.environment.suggestionSession)
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

    private func open(_ url: URL) {
        onSubmit(url)
        dismiss()
    }

    private func submit() {
        guard let url = MobileStore.url(fromInput: text) else { return }
        onSubmit(url)
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
