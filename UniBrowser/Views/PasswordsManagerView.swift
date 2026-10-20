import SwiftUI

/// ⌘⇧P: UniBrowser's own saved logins — view, copy, edit, delete, add by hand.
/// These live in the login keychain (KeychainCredentialProvider), separate from Apple Passwords.
struct PasswordsManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let store: KeychainCredentialProvider

    @State private var items: [Credential] = []
    @State private var error: String?
    @State private var editing: Credential?
    @State private var isAdding = false
    @State private var section = PasswordsSection.passwords
    @State private var sshEditing: SSHHost?

    private enum PasswordsSection { case passwords, ssh }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Пароли UniBrowser").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Picker("", selection: $section) {
                Text("Пароли").tag(PasswordsSection.passwords)
                Text("SSH").tag(PasswordsSection.ssh)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Divider()
            if section == .ssh {
                SSHHostsView(editing: $sshEditing)
            } else {
                passwordsContent
            }
        }
        .frame(width: 560, height: 520)
        .onAppear {
            reload()
            if let id = model.passwordsSSHHost {
                model.passwordsSSHHost = nil
                section = .ssh
                sshEditing = model.sshHosts.host(id)
            }
        }
        .sheet(item: $editing) { credential in
            PasswordEditor(original: credential, store: store) { reload() }
        }
        .sheet(isPresented: $isAdding) {
            PasswordEditor(original: nil, store: store) { reload() }
        }
    }

    @ViewBuilder
    private var passwordsContent: some View {
            storagePicker
            Divider()

            if items.isEmpty {
                Text("Пока нет сохранённых паролей. Они появляются, когда вы входите на сайт, или добавьте вручную.")
                    .foregroundStyle(Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    PasswordRow(item: item,
                                onCopy: { copy(item.password) },
                                onEdit: { editing = item },
                                onDelete: { delete(item) })
                }
            }

            Divider()
            HStack {
                if let error {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Импортировать из CSV…", action: importCSV)
                Button("Добавить…") { isAdding = true }
            }
            .padding(16)
    }

    private var storagePicker: some View {
        let passwords = model.passwords
        return VStack(alignment: .leading, spacing: 6) {
            Picker("Хранить пароли", selection: Bindable(passwords).storage) {
                Text("В UniBrowser").tag(PasswordStorage.builtIn)
                Text("В «Паролях» Apple").tag(PasswordStorage.apple)
            }
            .pickerStyle(.segmented)
            // Apple can't be picked until macOS runs the helper for UniBrowser; switching back always works.
            .disabled(!passwords.isAppleAvailable && passwords.storage == .builtIn)
            Text(storageNote)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var storageNote: String {
        let passwords = model.passwords
        switch passwords.storage {
        case .builtIn:
            return passwords.isAppleAvailable
                ? "Пароли хранятся только в UniBrowser и не видны в «Паролях» Apple."
                : "Пароли хранятся только в UniBrowser. «Пароли» Apple станут доступны, когда Apple разрешит UniBrowser к ним подключаться."
        case .apple:
            if !passwords.isAppleAvailable {
                return "macOS сейчас не даёт UniBrowser подключиться к «Паролям», поэтому пароли не подставляются и не сохраняются. Вернитесь к «В UniBrowser», чтобы пользоваться списком ниже."
            }
            return passwords.apple.state == .connected
                ? "Новые пароли сохраняются и подставляются только из «Паролей» Apple. Ниже — пароли, сохранённые раньше в UniBrowser; они не используются."
                : "Подключите «Пароли» (меню «Вкладки» → «Подключить «Пароли»…»). Пока подключения нет, пароли не подставляются и не сохраняются."
        }
    }

    private func reload() {
        Task {
            do { items = try await store.all(); error = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    private func delete(_ credential: Credential) {
        do { try store.delete(credential); reload() }
        catch { self.error = error.localizedDescription }
    }

    private func copy(_ password: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
    }

    /// Imports a CSV exported from the Passwords app (File ▸ Export All Passwords).
    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .text]
        panel.message = "CSV, экспортированный из приложения «Пароли»"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let count = try await store.importCSV(text)
                reload()
                error = count == 0 ? "В файле не нашлось логинов." : "Импортировано: \(count)."
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct PasswordRow: View {
    let item: Credential
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.host).font(.system(size: 14))
                Text(item.username.isEmpty ? "без имени" : item.username)
                    .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
            }
            Spacer()
            Text(isRevealed ? item.password : String(repeating: "•", count: min(item.password.count, 10)))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Palette.secondaryText)
                .textSelection(.enabled)
                .frame(width: 120, alignment: .trailing)
                .lineLimit(1)
            Button { isRevealed.toggle() } label: { Image(systemName: isRevealed ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRevealed ? "Скрыть пароль" : "Показать пароль")
            Button(action: onCopy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Скопировать пароль")
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Изменить")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Удалить")
        }
        .padding(.vertical, 2)
    }
}

/// Add or edit one login. Editing a username removes the old item and writes the new one,
/// because host+username is the identity of a keychain login.
private struct PasswordEditor: View {
    @Environment(\.dismiss) private var dismiss
    let original: Credential?
    let store: KeychainCredentialProvider
    let onSave: () -> Void

    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "Новый пароль" : "Изменить пароль").font(.system(size: 15, weight: .semibold))
            Form {
                TextField("Сайт (host)", text: $host)
                TextField("Имя пользователя", text: $username)
                SecureField("Пароль", text: $password)
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
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            host = original?.host ?? ""
            username = original?.username ?? ""
            password = original?.password ?? ""
        }
    }

    private func save() {
        let credential = Credential(host: host.trimmingCharacters(in: .whitespaces), username: username, password: password)
        Task {
            do {
                // A renamed username leaves a stale item behind; drop the old one first.
                if let original, original.id != credential.id { try store.delete(original) }
                try await store.save(credential)
                onSave()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
