import SwiftUI
import UniformTypeIdentifiers

/// «…» → «Настройки»: the Mac's settings groups that make sense on the phone.
struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Closes this sheet and opens the via-Mac settings.
    let onViaMacSettings: () -> Void

    @AppStorage(SearchEngine.defaultsKey) private var engine = SearchEngine.google
    @AppStorage(SearchSuggestions.enabledKey) private var suggestions = true
    @AppStorage(HomePage.key) private var startPage = ""
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage(SettingsKeys.historyRetentionDays) private var retention = 90
    @AppStorage(SettingsKeys.adBlockingEnabled) private var adBlocking = true
    @AppStorage(SettingsKeys.terminalSuggestions) private var terminalSuggestions = true
    @State private var confirmClear = false
    @State private var cleared = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Основные") {
                    Picker("Поисковая система", selection: $engine) {
                        ForEach(SearchEngine.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Подсказки поиска", isOn: $suggestions)
                    TextField("Стартовая страница", text: $startPage, prompt: Text("Стартовая страница (пусто — поиск)"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Оформление", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.title) }
                    }
                }
                Section("Конфиденциальность") {
                    Picker("Хранить историю", selection: $retention) {
                        Text("неделю").tag(7)
                        Text("месяц").tag(30)
                        Text("3 месяца").tag(90)
                        Text("год").tag(365)
                        Text("всегда").tag(0)
                    }
                    if let history = model.store.history { ClearHistoryButton(history: history) }
                    Button(cleared ? "Данные сайтов удалены" : "Удалить cookies и кэш («\(model.mode.title)»)…", role: .destructive) {
                        confirmClear = true
                    }
                    .disabled(cleared)
                    Toggle("Блокировать рекламу и трекеры", isOn: $adBlocking)
                }
                SitePermissionsSection(settings: model.siteSettings)
                Section("Пароли") {
                    LabeledContent("С Mac и сохранённые здесь", value: "\(model.passwords.all.count)")
                }
                Section("SSH") {
                    NavigationLink {
                        SSHHostsSettings { id in
                            dismiss()
                            model.store.openSSH(id)
                        }
                    } label: {
                        LabeledContent("SSH-серверы", value: "\(model.sshHosts.live.count)")
                    }
                    Toggle("Подсказки в терминале", isOn: $terminalSuggestions)
                }
                Section("Через Mac") {
                    Button("Настройки «Через Mac»") {
                        dismiss()
                        onViaMacSettings()
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
            .confirmationDialog("Удалить cookies, кэш и данные сайтов этого режима?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) {
                    Task {
                        await model.store.environment.eraseWebsiteData()
                        cleared = true
                    }
                }
            } message: {
                Text("Вы выйдете из аккаунтов на сайтах. Вкладки и пароли останутся.")
            }
        }
    }
}

/// «Сохранить как PDF»: the page as a PDF for the Files save sheet.
struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
