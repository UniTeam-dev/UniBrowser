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
        case .connected(.direct): "Напрямую"
        case .connected(.relay): "Через реле"
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
