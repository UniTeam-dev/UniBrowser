import SwiftUI
import WebKit

/// The main screen: the page, with the address and controls at the bottom
/// where a thumb reaches them.
struct BrowserScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showTabs = false
    @State private var showViaMacSettings = false
    @State private var isEditingAddress = false
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
                    StartPage(mode: model.mode, space: store.activeSpace) { isEditingAddress = true }
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
                onAddress: { isEditingAddress = true },
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
        .fullScreenCover(isPresented: $isEditingAddress) {
            AddressEntry(initialText: store.selectedTab?.url?.absoluteString ?? "") { input in
                store.open(input: input, inNewTab: store.selectedTab == nil)
            }
        }
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
    let onTabs: () -> Void
    let onSwitchMode: (BrowsingMode) -> Void
    let onViaMacSettings: () -> Void
    let onSendToMac: (URL) -> Void
    @AppStorage("appearance") var appearance = Appearance.system

    var body: some View {
        let tab = store.selectedTab
        VStack(spacing: 8) {
            Button(action: onAddress) {
                HStack(spacing: 6) {
                    if store.spaces.count > 1 || store.activeSpace.imageData != nil {
                        SpaceIcon(space: store.activeSpace, size: 18)
                    }
                    if mode == .viaMac {
                        Image(systemName: BrowsingMode.viaMac.systemImage)
                            .foregroundStyle(store.activeSpace.color)
                    }
                    Text(tab?.url?.host() ?? "Поиск или адрес")
                        .lineLimit(1)
                        .foregroundStyle(tab == nil ? .secondary : .primary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            HStack {
                Button { tab?.webView?.goBack() } label: { Image(systemName: "chevron.backward") }
                    .disabled(!(tab?.canGoBack ?? false))
                Spacer()
                Button { tab?.webView?.goForward() } label: { Image(systemName: "chevron.forward") }
                    .disabled(!(tab?.canGoForward ?? false))
                Spacer()
                Button { store.newTab(url: nil); onAddress() } label: { Image(systemName: "plus") }
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
                    if let tab {
                        Button("Обновить", systemImage: "arrow.clockwise") { tab.webView?.reload() }
                    }
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
                 ? "Вкладки вашего Mac. Рабочие сайты откроются через него."
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

/// Full-screen address entry with the keyboard up straight away.
private struct AddressEntry: View {
    let initialText: String
    let onSubmit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Поиск или адрес", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit {
                        onSubmit(text)
                        dismiss()
                    }
                    .padding()
                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .onAppear {
            text = initialText
            focused = true
        }
    }
}
