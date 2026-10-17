import SwiftUI

/// A strip above the page in the via-Mac mode when work sites can't load yet.
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
        if relay.workDomains.isEmpty { return "Добавьте рабочие домены, которые нужно открывать через Mac." }
        switch relay.status {
        case .connected: return nil
        case .connecting: return "Подключаюсь к Mac…"
        case .notPaired: return "Mac не подключён, рабочие сайты не откроются."
        case .unreachable(let reason): return reason
        }
    }
}

struct ViaMacSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newDomain = ""
    @State private var confirmErase = false

    var body: some View {
        let relay = model.relay
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Состояние", value: statusText)
                    Button("Сопрячь с Mac по QR-коду", systemImage: "qrcode.viewfinder") {}
                        .disabled(true)
                } header: {
                    Text("Mac")
                } footer: {
                    Text("Сопряжение и туннель до Mac появятся на следующем этапе.")
                }

                Section {
                    ForEach(relay.workDomains, id: \.self) { Text($0) }
                        .onDelete { relay.removeDomains(at: $0) }
                    HStack {
                        TextField("corp.example", text: $newDomain)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addDomain)
                        Button("Добавить", action: addDomain)
                            .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Рабочие домены")
                } footer: {
                    Text("Через Mac идут только эти домены и их поддомены, остальные сайты открываются напрямую с телефона.")
                }

                Section {
                    Button("Стереть данные режима", systemImage: "trash", role: .destructive) {
                        confirmErase = true
                    }
                } footer: {
                    Text("Удаляет вкладки, cookie и кэш режима «Через Mac». Обычный режим не затрагивается.")
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
        }
    }

    private var statusText: String {
        switch model.relay.status {
        case .notPaired: "Не сопряжён"
        case .connecting: "Подключение…"
        case .connected(.direct): "Подключён напрямую"
        case .connected(.relay): "Подключён через реле"
        case .unreachable: "Недоступен"
        }
    }

    private func addDomain() {
        model.relay.addDomain(newDomain)
        newDomain = ""
    }
}
