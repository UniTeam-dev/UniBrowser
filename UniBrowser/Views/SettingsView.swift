import SwiftUI
import WebKit

/// «UniBrowser → Настройки…» (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Основные", systemImage: "gearshape") }
            PrivacySettings().tabItem { Label("Конфиденциальность", systemImage: "hand.raised") }
            PasswordSettings().tabItem { Label("Пароли", systemImage: "key") }
            IPhoneSettings().tabItem { Label("iPhone", systemImage: "iphone") }
            ExtensionSettings().tabItem { Label("Расширения", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    /// Sheets open over the browser window; this brings it forward.
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SearchEngine.defaultsKey) private var engine = SearchEngine.google
    @AppStorage(SearchSuggestions.enabledKey) private var suggestions = true
    @AppStorage(HomePage.key) private var startPage = ""
    @AppStorage("appearance") private var appearance = Appearance.system

    var body: some View {
        Form {
            Picker("Поисковая система", selection: $engine) {
                ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Подсказки поиска в ⌘K", isOn: $suggestions)
            TextField("Стартовая страница", text: $startPage, prompt: Text("пусто — ⌘T открывает поиск"))
            Picker("Оформление", selection: $appearance) {
                ForEach(Appearance.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Другие браузеры") {
                Button("Импорт закладок и истории…") { model.isImportVisible = true; openWindow(id: "main") }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.historyRetentionDays) private var retention = 90
    @AppStorage(SettingsKeys.adBlockingEnabled) private var adBlocking = true
    @State private var confirmClear = false
    @State private var cleared = false

    var body: some View {
        Form {
            Picker("Хранить историю", selection: $retention) {
                Text("неделю").tag(7)
                Text("месяц").tag(30)
                Text("3 месяца").tag(90)
                Text("год").tag(365)
                Text("всегда").tag(0)
            }
            ClearHistoryButton(history: model.history)
            LabeledContent("Данные сайтов") {
                Button(cleared ? "Удалено" : "Удалить cookies и кэш…") { confirmClear = true }.disabled(cleared)
            }
            Toggle("Блокировать рекламу и трекеры", isOn: $adBlocking)
            SitePermissionsSection(settings: model.store.environment.siteSettings)
        }
        .formStyle(.grouped)
        .confirmationDialog("Удалить cookies, кэш и данные всех сайтов?", isPresented: $confirmClear) {
            Button("Удалить", role: .destructive) {
                Task {
                    let store = model.store.environment.dataStore
                    await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                    cleared = true
                }
            }
        } message: {
            Text("Вы выйдете из всех аккаунтов на сайтах. Сохранённые пароли останутся.")
        }
    }
}

private struct PasswordSettings: View {
    @Environment(AppModel.self) private var model
    /// Sheets open over the browser window; this brings it forward.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            LabeledContent("Приложение «Пароли»") {
                if model.passwords.apple.state == .connected {
                    Text("подключено").foregroundStyle(.secondary)
                } else {
                    Button("Подключить…") { Task { await model.passwords.apple.beginPairing() }; openWindow(id: "main") }
                }
            }
            LabeledContent("Пароли UniBrowser") {
                Button("Открыть…") { model.isPasswordsVisible = true; openWindow(id: "main") }
            }
            Text("Импорт из CSV (Пароли, Chrome) — в окне «Пароли UniBrowser».")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct IPhoneSettings: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Text("Вкладки, пароли и сеть Mac на iPhone: связь, QR-код для подключения и список iPhone.")
                .foregroundStyle(.secondary)
            LabeledContent("Связь с iPhone") {
                Button("Открыть…") { openWindow(id: "iphone") }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtensionSettings: View {
    @Environment(AppModel.self) private var model
    /// Sheets open over the browser window; this brings it forward.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            LabeledContent("Расширения Chrome и Safari") {
                Button("Управлять…") { model.isExtensionsVisible = true; openWindow(id: "main") }
            }
        }
        .formStyle(.grouped)
    }
}
