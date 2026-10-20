import SwiftUI

/// An `unibrowser-ssh` tab: «Терминал | Файлы», the route in the status line, the login state over the terminal.
struct SSHTabScreen: View {
    @Environment(AppModel.self) private var model
    let tab: MobileTab
    let hostID: UUID
    @State private var pane = Pane.terminal
    @State private var editing: SSHHost?

    private enum Pane: String, CaseIterable {
        case terminal = "Терминал", files = "Файлы"
    }

    var body: some View {
        if let host = model.sshHosts.host(hostID) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("Раздел", selection: $pane) {
                        ForEach(Pane.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer(minLength: 0)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                ZStack {
                    if let session = tab.sshSession, let terminal = tab.sshTerminal, let files = tab.sshFiles {
                        switch pane {
                        case .terminal: TerminalHost(terminal: terminal)
                        case .files: FilesScreen(session: session, browser: files)
                        }
                        status(session, host: host)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Wakes on appear, and again if the tab is put to sleep while on screen.
            .task(id: tab.sshSession == nil) {
                guard tab.sshSession == nil else { return }
                let route: SSHRoute = host.viaMac ? .socks(host: "127.0.0.1", port: Int(MacRelay.localProxyPort.rawValue)) : .direct
                tab.wakeSSH(host: host, secret: model.sshHosts.secret(for: hostID), knownHosts: model.knownHosts,
                            history: model.sshHistory(for: hostID), route: route)
                tab.sshTerminal?.connect()
            }
            .onChange(of: host.displayName, initial: true) { tab.title = host.displayName }
            // Logged in: the keyboard comes up for the shell.
            .onChange(of: tab.sshSession?.state == .connected) { _, connected in
                if connected, pane == .terminal { _ = tab.sshTerminal?.becomeFirstResponder() }
            }
            .onChange(of: pane) { _, pane in
                if pane == .files { _ = tab.sshTerminal?.resignFirstResponder() }
            }
            .sheet(item: hostKeyPrompt) { prompt in
                HostKeySheet(key: prompt.key, previous: prompt.previous) { tab.sshSession?.answerHostKey(trust: $0) }
            }
            .sheet(item: $editing) { SSHHostForm(original: $0) }
        } else {
            card {
                Text("Сервер удалён из хранилища").font(.title3.weight(.semibold))
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { tab.sleep() }
        }
    }

    /// «Напрямую» or «Через Mac»; «Новая сессия» after the app came back and logged in again.
    private var statusLine: String {
        tab.sshRoute.label + (tab.isNewSSHSession ? " · Новая сессия" : "")
    }

    @ViewBuilder
    private func status(_ session: SSHSession, host: SSHHost) -> some View {
        switch session.state {
        case .idle, .connecting:
            card {
                ProgressView()
                Text("Подключение к \(host.displayName)…").multilineTextAlignment(.center)
            }
        case .failed(let message):
            failure(message, host: host)
        case .closed:
            failure("Сессия завершена", host: host)
        case .hostKeyPrompt, .connected:
            EmptyView()
        }
    }

    private func failure(_ message: String, host: SSHHost) -> some View {
        card {
            Text(message).font(.headline).multilineTextAlignment(.center)
            if message == SSHSession.noMacLinkMessage {
                Text("Подключусь, как только появится связь с Mac.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack {
                Button("Изменить сервер") { editing = host }
                    .buttonStyle(.bordered)
                Button("Переподключиться") {
                    tab.isNewSSHSession = false
                    tab.sshTerminal?.connect()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 12, content: content)
            .padding(20)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private struct Prompt: Identifiable {
        let key: KnownHost
        let previous: KnownHost?
        var id: String { key.fingerprintSHA256 }
    }

    /// Dismissing the sheet any other way than its buttons counts as «Отмена».
    private var hostKeyPrompt: Binding<Prompt?> {
        Binding(
            get: {
                guard case .hostKeyPrompt(let key, let previous) = tab.sshSession?.state else { return nil }
                return Prompt(key: key, previous: previous)
            },
            set: { if $0 == nil { tab.sshSession?.answerHostKey(trust: false) } }
        )
    }
}

/// The server's key is new or changed: trust it or cancel. A changed key is shown in red with the
/// old and new fingerprints, and «Заменить ключ» asks again before trusting.
private struct HostKeySheet: View {
    let key: KnownHost
    let previous: KnownHost?
    let answer: (Bool) -> Void
    @State private var isConfirmingReplace = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let previous {
                        Label("Ключ сервера \(key.hostPort) изменился", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("Возможно, сервер переустановлен — или кто-то перехватывает подключение.")
                            .foregroundStyle(.red)
                        fingerprint("Был", previous)
                        fingerprint("Сейчас", key)
                    } else {
                        Text("Новый сервер \(key.hostPort)").font(.headline)
                        Text("Сверьте отпечаток ключа с тем, что показывает сервер.")
                            .foregroundStyle(.secondary)
                        fingerprint("Отпечаток", key)
                    }
                }
                Section {
                    if previous == nil {
                        Button("Доверять") { answer(true) }
                    } else {
                        Button("Заменить ключ", role: .destructive) { isConfirmingReplace = true }
                    }
                    Button("Отмена", role: .cancel) { answer(false) }
                }
            }
            .navigationTitle("Ключ сервера")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .alert("Заменить ключ сервера?", isPresented: $isConfirmingReplace) {
            Button("Заменить ключ", role: .destructive) { answer(true) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Подключайтесь, только если знаете, почему ключ \(key.hostPort) изменился.")
        }
    }

    private func fingerprint(_ title: String, _ key: KnownHost) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) · \(key.keyType)").font(.caption).foregroundStyle(.secondary)
            Text(key.fingerprintSHA256)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(previous == nil ? .primary : Color.red)
        }
    }
}
