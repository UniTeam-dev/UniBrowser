import SwiftUI
import WebKit

/// The main screen: the page, with the address and controls at the bottom
/// where a thumb reaches them.
struct BrowserScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showTabs = false
    @State private var showViaMacSettings = false
    @State private var isEditingAddress = false

    var body: some View {
        let store = model.store
        VStack(spacing: 0) {
            if model.mode == .viaMac {
                ViaMacBanner(relay: model.relay) { showViaMacSettings = true }
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
            }
            BottomBar(
                store: store,
                mode: model.mode,
                onAddress: { isEditingAddress = true },
                onTabs: { showTabs = true },
                onSwitchMode: { model.switchMode(to: $0) },
                onViaMacSettings: { showViaMacSettings = true }
            )
        }
        .sheet(isPresented: $showTabs) {
            TabsSheet(store: store)
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

private struct BottomBar: View {
    let store: MobileStore
    let mode: BrowsingMode
    let onAddress: () -> Void
    let onTabs: () -> Void
    let onSwitchMode: (BrowsingMode) -> Void
    let onViaMacSettings: () -> Void

    var body: some View {
        let tab = store.selectedTab
        VStack(spacing: 8) {
            Button(action: onAddress) {
                HStack(spacing: 6) {
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
                    Picker("Режим", selection: Binding(get: { mode }, set: onSwitchMode)) {
                        ForEach(BrowsingMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
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
            Image(systemName: mode.systemImage)
                .font(.system(size: 44))
                .foregroundStyle(space.color)
            Text(space.name).font(.title2.bold())
            Text(mode == .viaMac
                 ? "Рабочие сайты откроются через ваш Mac."
                 : "Откройте сайт или найдите что-нибудь.")
                .foregroundStyle(.secondary)
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
