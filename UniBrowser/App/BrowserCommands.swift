import SwiftUI
import WebKit

struct BrowserCommands: Commands {
    let main: AppModel
    @Environment(\.openWindow) private var openWindow
    /// The private window's model while one is key.
    @FocusedValue(\.appModel) private var focused
    /// The model of the key browser window: a private one, or the main one.
    private var model: AppModel { focused ?? main }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новая вкладка") { model.openPalette(.newTab) }
                .keyboardShortcut("t")
            Button("Новое приватное окно") { openWindow(id: "private") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Новая группа") { model.store.newGroup(named: "Новая группа") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Закрыть вкладку") { model.store.closeSelectedTab() }
                .keyboardShortcut("w")
        }

        CommandMenu("Вкладки") {
            Button("Поиск по вкладкам и командам") { model.openPalette(.search) }
                .keyboardShortcut("k")
            Button("Открыть адрес") { model.openPalette(.address) }
                .keyboardShortcut("l")
            Button("Карта вкладок") { model.openTabMap() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Divider()
            Button("Назад") { model.store.selectedTab?.webView?.goBack() }
                .keyboardShortcut("[")
            Button("Вперёд") { model.store.selectedTab?.webView?.goForward() }
                .keyboardShortcut("]")
            Button("Обновить") { model.store.selectedTab?.webView?.reload() }
                .keyboardShortcut("r")
            Divider()
            Button("Расширения…") { model.isExtensionsVisible = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Пароли UniBrowser…") { model.isPasswordsVisible = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Подключить «Пароли»…") { Task { await model.passwords.apple.beginPairing() } }
                .disabled(model.passwords.apple.state == .connected)
            Button("iPhone…") { openWindow(id: "iphone") }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Закрепить вкладку") {
                if let id = model.store.activeSpace.selectedTabID { model.store.togglePin(id) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        CommandMenu("Пространства") {
            ForEach(Array(model.store.spaces.enumerated()), id: \.element.id) { index, space in
                Button(space.name) { model.store.switchToSpace(at: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(min(index + 1, 9))")), modifiers: .control)
            }
            Divider()
            Button("Новое пространство") { model.store.newSpace(named: "Пространство \(model.store.spaces.count + 1)") }
        }

        CommandMenu("Разработка") {
            // F12 also toggles it; AppModel's key monitor handles that (one shortcut per item).
            Button("Инструменты разработчика") { model.toggleDevTools() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Консоль JavaScript") { model.store.selectedTab?.devTools?.open(.console) }
                .keyboardShortcut("j", modifiers: [.command, .option])
            Button("Выбрать элемент на странице") {
                guard let devTools = model.store.selectedTab?.devTools else { return }
                devTools.open(.elements)
                devTools.elements.pick()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            // ⇧⌘M (spec) is «Карта вкладок», so ⌥⇧⌘M.
            Button("Режим устройства") { model.store.selectedTab?.deviceMode.isOn.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .option, .shift])
            Button("Жёсткая перезагрузка") { model.store.selectedTab?.webView?.reloadFromOrigin() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Web Inspector") { inspect(WebInspector.toggle) }
                .keyboardShortcut("u", modifiers: [.command, .option])
        }

        CommandGroup(after: .sidebar) {
            Button(model.isSidebarCompact ? "Полная панель вкладок" : "Компактная панель вкладок") {
                withAnimation(.snappy) { model.isSidebarCompact.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }

    private func inspect(_ action: (WKWebView) -> Void) {
        if let webView = model.store.selectedTab?.webView { action(webView) }
    }
}
