import SwiftUI
import UniformTypeIdentifiers

/// «Настройки» → «SSH-серверы»: saved servers, add / edit / delete / open in a tab.
struct SSHHostsSettings: View {
    @Environment(AppModel.self) private var model
    /// Opens the host in a new tab of the mode on screen and closes «Настройки».
    let onOpen: (UUID) -> Void

    @State private var editing: SSHHost?
    @State private var isAdding = false
    @State private var deleting: SSHHost?

    var body: some View {
        let hosts = model.sshHosts.live
        List {
            if hosts.isEmpty {
                Text("Пока нет серверов. Добавьте сервер, чтобы открывать его во вкладке.")
                    .foregroundStyle(.secondary)
            }
            ForEach(hosts) { host in
                Menu {
                    Button("Открыть во вкладке", systemImage: "terminal") { onOpen(host.id) }
                    Button("Изменить", systemImage: "pencil") { editing = host }
                    Button("Удалить…", systemImage: "trash", role: .destructive) { deleting = host }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "terminal").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.displayName)
                            Text(verbatim: "\(host.username)@\(host.address)" + (host.port == 22 ? "" : ":\(host.port)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if host.viaMac { Image(systemName: "laptopcomputer").foregroundStyle(.secondary).accessibilityLabel("Через Mac") }
                    }
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button("Удалить", role: .destructive) { deleting = host }
                }
            }
        }
        .navigationTitle("SSH-серверы")
        .toolbar {
            Button("Добавить", systemImage: "plus") { isAdding = true }
        }
        .sheet(item: $editing) { SSHHostForm(original: $0) }
        .sheet(isPresented: $isAdding) { SSHHostForm(original: nil) }
        .confirmationDialog("Удалить сервер «\(deleting?.displayName ?? "")»?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { host in
            Button("Удалить", role: .destructive) { model.sshHosts.delete(host.id) }
            Button("Отмена", role: .cancel) {}
        } message: { host in
            let count = model.sshTabs.filter { $0.url?.sshHostID == host.id && $0.sshSession != nil }.count
            Text((count == 0 ? "" : "Открытые вкладки этого сервера будут отключены: \(count). ") + "Пароль или ключ тоже будут удалены.")
        }
    }
}

/// Add or edit one SSH server, with its password or key. A stored private key is never shown:
/// «Ключ сохранён» keeps it, «Заменить…» takes a new one.
struct SSHHostForm: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let original: SSHHost?

    @State private var name = ""
    @State private var address = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var auth = SSHHost.Auth.password
    @State private var viaMac = false
    @State private var password = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var error: String?
    @State private var notice: String?
    /// The stored secret of the edited host; untouched, its key is kept as it is.
    @State private var stored = SSHSecret()
    @State private var isReplacingKey = false
    @State private var isGenerateConfirmVisible = false
    @State private var isImporting = false

    private var keepsStoredKey: Bool { stored.privateKey != nil && !isReplacingKey }
    private var hasTypedKey: Bool { !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name, prompt: Text("Название (необязательно)"))
                    TextField("Адрес", text: $address)
                        .keyboardType(.URL)
                    LabeledContent("Порт") {
                        TextField("22", text: $port)
                            .keyboardType(.numbersAndPunctuation) // has a return key, unlike the number pad
                            .multilineTextAlignment(.trailing)
                    }
                    TextField("Пользователь", text: $username)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Section("Вход") {
                    Picker("Вход", selection: $auth) {
                        Text("Пароль").tag(SSHHost.Auth.password)
                        Text("Ключ").tag(SSHHost.Auth.key)
                    }
                    .pickerStyle(.segmented)
                    if auth == .password {
                        SecureField("Пароль", text: $password)
                    } else {
                        keyRows
                    }
                }
                Section {
                    Toggle("Через Mac", isOn: $viaMac)
                } footer: {
                    Text("Подключаться через сеть сопряжённого Mac — например, к серверу в домашней сети.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(original == nil ? "Новый сервер" : "Изменить сервер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save) }
            }
            .onAppear(perform: load)
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result { importKey(url) }
            }
            .confirmationDialog("Заменить ключ?", isPresented: $isGenerateConfirmVisible, titleVisibility: .visible) {
                Button("Сгенерировать новый", role: .destructive, action: generate)
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Текущий ключ будет заменён новым. Если он нужен, сначала скопируйте публичный ключ или сохраните приватный.")
            }
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var keyRows: some View {
        if keepsStoredKey {
            HStack {
                Label("Ключ сохранён", systemImage: "key.fill")
                Spacer()
                Button("Заменить…") { isReplacingKey = true; key = ""; passphrase = "" }
                    .buttonStyle(.borderless)
            }
        } else {
            TextEditor(text: $key)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 90)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Приватный ключ")
                .overlay(alignment: .topLeading) {
                    if key.isEmpty {
                        Text("Вставьте приватный ключ (OpenSSH) или импортируйте файл.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
            // The system paste button: no «Разрешить вставку?» prompt.
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                isReplacingKey = true
                key = SSHKeys.normalized(text)
                passphrase = ""
                error = nil
            }
            if SSHKeys.isEncrypted(SSHKeys.normalized(key)) {
                SecureField("Парольная фраза ключа", text: $passphrase)
            }
        }
        Button("Импортировать…", systemImage: "square.and.arrow.down") { isImporting = true }
        Button("Сгенерировать ed25519", systemImage: "wand.and.stars") {
            if keepsStoredKey || hasTypedKey { isGenerateConfirmVisible = true } else { generate() }
        }
        Button("Скопировать публичный ключ", systemImage: "doc.on.doc", action: copyPublicKey)
            .disabled(!keepsStoredKey && !hasTypedKey)
    }

    private func generate() {
        isReplacingKey = true
        key = SSHKeys.generateEd25519()
        passphrase = ""
        error = nil
    }

    private func load() {
        guard let original else { return }
        name = original.name
        address = original.address
        port = String(original.port)
        username = original.username
        auth = original.auth
        viaMac = original.viaMac
        stored = model.sshHosts.secret(for: original.id)
        password = stored.password ?? ""
    }

    private func importKey(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            error = "Не удалось прочитать файл как текст."
            return
        }
        isReplacingKey = true
        key = SSHKeys.normalized(text)
        passphrase = ""
        error = nil
    }

    private func copyPublicKey() {
        let comment = "unibrowser@" + UIDevice.current.name
        do {
            let line = keepsStoredKey
                ? try SSHKeys.publicKeyLine(stored.privateKey ?? "", passphrase: stored.passphrase, comment: comment)
                : try SSHKeys.publicKeyLine(SSHKeys.normalized(key), passphrase: passphrase, comment: comment)
            UIPasteboard.general.string = line
            error = nil
            show("Публичный ключ скопирован")
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func show(_ text: String) {
        withAnimation { notice = text }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if notice == text { notice = nil } }
        }
    }

    private func save() {
        let draft = SSHHostDraft(name: name, address: address, port: port, username: username, auth: auth, viaMac: viaMac,
                                 password: password, key: key, passphrase: passphrase, storedKey: keepsStoredKey ? stored : nil)
        do {
            let (host, secret) = try draft.build(id: original?.id ?? UUID())
            try model.sshHosts.save(host, secret: secret)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
