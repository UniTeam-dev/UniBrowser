import SwiftUI

struct BrowserCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Новая вкладка") { model.openPalette(.newTab) }
                .keyboardShortcut("t")
            Button("Новая группа") { model.store.newGroup(named: "Новая группа") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Закрыть вкладку") { model.store.closeSelectedTab() }
                .keyboardShortcut("w")
        }

        CommandMenu("Вкладки") {
            Button("Поиск по вкладкам и командам") { model.openPalette(.search) }
                .keyboardShortcut("k")
            Button("Открыть адрес") { model.openPalette(.search) }
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

        CommandGroup(after: .sidebar) {
            Button(model.isSidebarVisible ? "Скрыть панель вкладок" : "Показать панель вкладок") {
                withAnimation(.snappy) { model.isSidebarVisible.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }
}
