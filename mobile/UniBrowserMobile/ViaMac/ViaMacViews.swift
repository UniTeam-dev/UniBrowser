import SwiftUI

/// A strip above the page in the via-Mac mode while pages can't load because the Mac isn't reachable.
struct ViaMacBanner: View {
    let relay: MacRelay
    let onSetup: () -> Void

    var body: some View {
        if let message {
            Button(action: onSetup) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(message).font(.footnote).multilineTextAlignment(.leading)
                    Spacer()
                    Text("Настроить").font(.footnote.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.15))
            }
            .buttonStyle(.plain)
        }
    }

    private var message: String? {
        switch relay.status {
        case .notPaired: return "Mac не подключён, страницы этого режима не откроются."
        case .connecting: return "Подключаюсь к Mac…"
        case .unreachable(let reason): return reason
        case .connected: return nil
        }
    }
}

/// «Подключение»: how the phone reaches the Mac from other networks — what the Mac sent,
/// and this phone's own values for when the Mac's are out of date. Applied on Return.
private struct ViaMacConnectionSection: View {
    let relay: MacRelay
    let mac: MacRelay.PairedMac
    @State private var external = ""
    @State private var server = ""

    var body: some View {
        Section {
            LabeledContent("Адреса Mac", value: mac.addresses?.isEmpty == false ? mac.addresses!.joined(separator: "\n") : "—")
            LabeledContent("Внешний адрес от Mac", value: mac.externalAddress ?? "Не задан")
            TextField("Внешний адрес Mac", text: $external, prompt: Text(mac.externalAddress ?? "IP или имя, как на Mac"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit(apply)
            if !external.isEmpty, ViaMacAddress.parse(external, defaultPort: 1) == nil {
                Text("Нужен IP-адрес или имя, при желании с портом: 203.0.113.7:47802").font(.footnote).foregroundStyle(.red)
            }
            LabeledContent("Сервер связи от Mac", value: mac.relayURL ?? "Не известен")
            TextField("Сервер связи", text: $server, prompt: Text("https://… — пусто: как на Mac"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onSubmit(apply)
            if !server.isEmpty, !ViaMacAddress.isValidRelay(server) {
                Text("Нужен адрес вида https://relay.example.ru").font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Подключение")
        } footer: {
            Text("Mac сообщает свои адреса и сервер связи при каждом подключении. Если они устарели, укажите здесь свои: пустое поле — как на Mac. Применяется при следующем подключении.")
        }
        .onAppear {
            external = relay.externalAddressOverride
            server = relay.relayOverride
        }
        .onDisappear(perform: apply)
    }

    private func apply() {
        let external = external.trimmingCharacters(in: .whitespaces)
        let server = server.trimmingCharacters(in: .whitespaces)
        guard external != relay.externalAddressOverride || server != relay.relayOverride else { return }
        relay.externalAddressOverride = external
        relay.relayOverride = server
        relay.reconnectNow()
    }
}

struct ViaMacSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pairingLink = ""
    @State private var isPairing = false
    @State private var confirmErase = false
    @State private var confirmUnpair = false

    var body: some View {
        let relay = model.relay
        NavigationStack {
            Form {
                Section {
                    if let mac = relay.pairedMac {
                        LabeledContent("Mac", value: mac.name)
                        LabeledContent("Связь", value: statusText)
                        LabeledContent("Вкладки", value: relay.isSyncing ? "Синхронизируются" : "Ждут связи с Mac")
                        LabeledContent("Пароли", value: "\(model.passwords.all.count)")
                        if case .unreachable = relay.status {
                            Button("Переподключиться", systemImage: "arrow.clockwise") { relay.reconnectNow() }
                        }
                        Button("Отвязать Mac", systemImage: "link.badge.minus", role: .destructive) {
                            confirmUnpair = true
                        }
                    } else {
                        Text("На Mac в UniBrowser откройте меню «Вкладки» → «iPhone…» (⇧⌘I), включите «Связь с iPhone» и нажмите «Показать QR-код». Наведите на него камеру iPhone и откройте ссылку в UniBrowser.")
                            .font(.callout)
                        TextField("…или вставьте скопированный код", text: $pairingLink, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            pair(pairingLink)
                        } label: {
                            if isPairing { ProgressView() } else { Text("Подключить") }
                        }
                        .disabled(pairingLink.isEmpty || isPairing)
                    }
                    if let error = relay.lastError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Вкладки, группы и пространства режима «Через Mac» — это вкладки вашего Mac: изменения с обеих сторон видны сразу, а после разлуки объединяются. Сохранённые пароли UniBrowser приходят с Mac. Все страницы этого режима открываются через сеть Mac: домашний NAS, сервер или роутер доступны и из мобильного интернета. Mac должен быть включён и не спать.")
                }

                if let mac = relay.pairedMac {
                    ViaMacConnectionSection(relay: relay, mac: mac)
                }

                Section {
                    Button("Стереть данные режима", systemImage: "trash", role: .destructive) {
                        confirmErase = true
                    }
                } footer: {
                    Text("Удаляет с телефона копию вкладок, пароли с Mac, cookie и кэш режима «Через Mac». На Mac ничего не удаляется. Обычный режим не затрагивается.")
                }
            }
            .navigationTitle("Через Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog("Стереть данные режима «Через Mac»?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Стереть", role: .destructive) {
                    Task { await model.eraseViaMacData() }
                }
            }
            .confirmationDialog("Отвязать Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Отвязать", role: .destructive) {
                    Task { await relay.unpair() }
                }
            } message: {
                Text("Чтобы подключиться снова, понадобится новый QR-код с Mac.")
            }
        }
    }

    private var statusText: String {
        switch model.relay.status {
        case .notPaired: "Не сопряжён"
        case .connecting: "Подключение…"
        case .connected(let path): path.title
        case .unreachable: "Недоступен"
        }
    }

    private func pair(_ link: String) {
        isPairing = true
        Task {
            await model.relay.pair(using: link)
            isPairing = false
            if model.relay.pairedMac != nil { pairingLink = "" }
        }
    }
}
