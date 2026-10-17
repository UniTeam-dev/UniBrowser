import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarView()
                    .frame(width: 260)
                    .transition(.move(edge: .leading))
            }
            ContentArea()
                .padding(model.isSidebarVisible ? EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 8) : EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
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

/// The white card holding the current page.
struct ContentArea: View {
    @Environment(AppModel.self) private var model
    @Environment(BrowserStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            if let tab = store.selectedTab {
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
            } else {
                EmptyTabView()
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(.black.opacity(0.06)))
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
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.window?.makeFirstResponder(webView)
    }
}
