import SwiftUI

/// Add or edit one SSH server, with its password or key.
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
    /// The stored secret of the edited host. Its private key is never shown; untouched, it is kept as it is.
    @State private var stored = SSHSecret()
    @State private var isReplacingKey = false
    @State private var isGenerateConfirmVisible = false
    @State private var deviceName = "mac"

    private var keepsStoredKey: Bool { stored.privateKey != nil && !isReplacingKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "Новый сервер" : "Изменить сервер").font(.system(size: 15, weight: .semibold))
            Form {
                TextField("Название", text: $name, prompt: Text("необязательно"))
                TextField("Адрес", text: $address)
                TextField("Порт", text: $port)
                TextField("Пользователь", text: $username)
                Picker("Вход", selection: $auth) {
                    Text("Пароль").tag(SSHHost.Auth.password)
                    Text("Ключ").tag(SSHHost.Auth.key)
                }
                .pickerStyle(.segmented)
                if auth == .password {
                    SecureField("Пароль", text: $password)
                } else {
                    keyArea
                }
                Toggle("Через Mac (для iPhone)", isOn: $viaMac)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить", action: save)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: load)
        .task {
            // The host name can need a lookup; keep it off the main thread.
            let name = await Task.detached { ProcessInfo.processInfo.hostName }.value
            deviceName = name.hasSuffix(".local") ? String(name.dropLast(6)) : (name.isEmpty ? "mac" : name)
        }
        .confirmationDialog("Заменить ключ?", isPresented: $isGenerateConfirmVisible) {
            Button("Сгенерировать новый", role: .destructive, action: generate)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текущий ключ будет заменён новым. Если он нужен, сначала скопируйте публичный ключ или сохраните приватный.")
        }
    }

    private var keyArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            if keepsStoredKey {
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(Palette.secondaryText)
                    Text("Ключ сохранён")
                    Spacer()
                    Button("Заменить…") { isReplacingKey = true; key = ""; passphrase = "" }
                }
            } else {
                TextEditor(text: $key)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15)))
                    .accessibilityLabel("Приватный ключ")
                if key.isEmpty {
                    Text("Вставьте приватный ключ (OpenSSH) или импортируйте файл.")
                        .font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                }
            }
            HStack {
                Button("Импортировать…", action: importKey)
                Button("Сгенерировать ed25519") {
                    if keepsStoredKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        isGenerateConfirmVisible = true
                    } else {
                        generate()
                    }
                }
                Button("Скопировать публичный ключ", action: copyPublicKey)
                    .disabled(!keepsStoredKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !keepsStoredKey, SSHKeys.isEncrypted(Self.normalized(key)) {
                SecureField("Парольная фраза ключа", text: $passphrase)
            }
        }
    }

    private func generate() {
        isReplacingKey = true
        key = SSHKeys.generateEd25519()
        passphrase = ""
        error = nil
    }

    /// Trimmed, LF line endings, one trailing newline: what the parser and the server-side tools expect.
    static func normalized(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return t.isEmpty ? "" : t + "\n"
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

    private func importKey() {
        let panel = NSOpenPanel()
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.message = "Приватный ключ SSH (OpenSSH)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            error = "Не удалось прочитать файл как текст."
            return
        }
        isReplacingKey = true
        key = Self.normalized(text)
        passphrase = ""
        error = nil
    }

    private func copyPublicKey() {
        let comment = "unibrowser@" + deviceName
        do {
            let line = keepsStoredKey
                ? try SSHKeys.publicKeyLine(stored.privateKey ?? "", passphrase: stored.passphrase, comment: comment)
                : try SSHKeys.publicKeyLine(Self.normalized(key), passphrase: passphrase, comment: comment)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(line, forType: .string)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        let address = address.trimmingCharacters(in: .whitespaces)
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return error = "Укажите адрес сервера." }
        guard let port = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            return error = "Порт — число от 1 до 65535."
        }
        guard !username.isEmpty else { return error = "Укажите пользователя." }

        var secret = SSHSecret()
        if auth == .password {
            secret.password = password
        } else {
            if keepsStoredKey {
                secret.privateKey = stored.privateKey
                secret.passphrase = stored.passphrase
            } else {
                let pem = Self.normalized(key)
                guard !pem.isEmpty else { return error = "Вставьте или импортируйте приватный ключ." }
                do { _ = try SSHKeys.parse(pem, passphrase: passphrase) } catch { return self.error = error.localizedDescription }
                secret.privateKey = pem
                if SSHKeys.isEncrypted(pem) { secret.passphrase = passphrase }
            }
        }
        let host = SSHHost(id: original?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), address: address,
                           port: port, username: username, auth: auth, viaMac: viaMac)
        do {
            try model.sshHosts.save(host, secret: secret)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
